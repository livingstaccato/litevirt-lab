package main

import (
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

// mac is an Ethernet address.
type mac [6]byte

// group reports whether m is a broadcast or multicast address (the I/G bit).
func (m mac) group() bool { return m[0]&1 == 1 }

// minFrame is an Ethernet header: destination, source, ethertype.
const minFrame = 14

type macEntry struct {
	peer string
	seen time.Time
}

// peer is one VM NIC: a Unix datagram socket the hub sends to, keyed by path.
type peer struct {
	fd    int       // the hub's own send socket for this peer; -1 until first send
	heard time.Time // last frame received from it (zero: never)
	inDir bool      // its socket file is in the peers directory

	rx, tx, full, gone uint64
}

// counters are the hub-wide frame counters, written to the stats file.
type counters struct {
	rxFrames, rxBytes   uint64
	unicast             uint64 // frames sent to exactly one learned peer
	flooded             uint64 // frames flooded (broadcast, multicast, unknown unicast)
	copies              uint64 // datagrams sent, one per target
	dropFull, dropGone  uint64 // target queue full / target socket gone (VM stopped)
	dropRunt, dropLocal uint64 // shorter than a header / destination is on the sender's port
	sendErr             uint64
}

// hub is the forwarding state: which MAC lives behind which peer, and which
// peers exist. It does no I/O, so the decisions can be tested directly.
type hub struct {
	macAge  time.Duration // a learned MAC is forgotten after this much silence
	peerAge time.Duration // a peer outside the peers dir is dropped after this much silence
	macs    map[mac]macEntry
	peers   map[string]*peer
	c       counters
}

func newHub(macAge, peerAge time.Duration) *hub {
	return &hub{macAge: macAge, peerAge: peerAge, macs: map[mac]macEntry{}, peers: map[string]*peer{}}
}

func (h *hub) addPeer(path string) *peer {
	p := h.peers[path]
	if p == nil {
		p = &peer{fd: -1}
		h.peers[path] = p
	}
	return p
}

// targets learns frame's source MAC on port from and returns the peers the
// frame goes to: the one peer a learned unicast destination lives behind, or
// every peer but the sender. Never the sender itself.
func (h *hub) targets(from string, frame []byte, now time.Time) []string {
	if len(frame) < minFrame {
		h.c.dropRunt++
		return nil
	}
	var dst, src mac
	copy(dst[:], frame[0:6])
	copy(src[:], frame[6:12])

	h.c.rxFrames++
	h.c.rxBytes += uint64(len(frame))
	if from != "" {
		p := h.addPeer(from)
		p.heard = now
		p.rx++
		if !src.group() {
			h.macs[src] = macEntry{peer: from, seen: now}
		}
	}

	if !dst.group() {
		if e, ok := h.macs[dst]; ok && now.Sub(e.seen) < h.macAge {
			if e.peer == from {
				h.c.dropLocal++ // a switch never sends a frame back out the port it came in on
				return nil
			}
			if _, live := h.peers[e.peer]; live {
				h.c.unicast++
				return []string{e.peer}
			}
		}
	}
	out := make([]string, 0, len(h.peers))
	for path := range h.peers {
		if path != from {
			out = append(out, path)
		}
	}
	sort.Strings(out)
	h.c.flooded++
	return out
}

// sync reconciles the peer set with the peers directory (every *.sock socket
// in it is a peer, whether or not it has sent anything yet: a NIC with no
// address, like a VLAN trunk, may never speak first), ages out silent MACs, and
// drops peers that are neither in the directory nor recently heard from. It
// returns the paths of peers it removed so the caller can close their sockets.
func (h *hub) sync(dirPeers map[string]bool, now time.Time) (removed []*peer, added, gone []string) {
	for path := range dirPeers {
		p, known := h.peers[path]
		if !known {
			p = h.addPeer(path)
			added = append(added, path)
		}
		p.inDir = true
	}
	for path, p := range h.peers {
		if dirPeers[path] {
			continue
		}
		p.inDir = false
		if p.heard.IsZero() || now.Sub(p.heard) >= h.peerAge {
			delete(h.peers, path)
			removed = append(removed, p)
			gone = append(gone, path)
		}
	}
	for m, e := range h.macs {
		if now.Sub(e.seen) >= h.macAge {
			delete(h.macs, m)
		} else if _, ok := h.peers[e.peer]; !ok {
			delete(h.macs, m)
		}
	}
	sort.Strings(added)
	sort.Strings(gone)
	return removed, added, gone
}

// scanDir lists the sockets in dir. A missing dir is an empty peer set.
func scanDir(dir string) map[string]bool {
	out := map[string]bool{}
	ents, err := os.ReadDir(dir)
	if err != nil {
		return out
	}
	for _, e := range ents {
		if !strings.HasSuffix(e.Name(), ".sock") || e.Type()&os.ModeSocket == 0 {
			continue
		}
		out[filepath.Join(dir, e.Name())] = true
	}
	return out
}
