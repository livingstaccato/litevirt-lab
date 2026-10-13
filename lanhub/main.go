// lanhub is a learning Ethernet hub for qemu `-netdev dgram` NICs on Unix
// datagram sockets: one process per virtual LAN, nothing on any host network.
//
// Every VM NIC on the LAN is a qemu dgram netdev whose local socket lives in
// the peers directory and whose remote is the hub socket:
//
//	-netdev dgram,id=net1,local.type=unix,local.path=<peers>/<vm>.sock,
//	        remote.type=unix,remote.path=<hub.sock>
//
// Each datagram is one Ethernet frame. The hub learns which peer a source MAC
// lives behind, sends a frame for a learned MAC to that peer only, and floods
// broadcast, multicast and unknown unicast to every other peer — never back to
// the sender. Sends never block: each peer gets its own send socket and
// MSG_DONTWAIT, so a VM that is not reading (booting, paused) or is gone
// (stopped, stale socket file) loses its own frames and nobody else's.
package main

import (
	"errors"
	"flag"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"sort"
	"syscall"
	"time"
)

// maxFrame bounds one datagram: above qemu's 4096+65536 net buffer, so any
// jumbo frame a guest can send fits.
const maxFrame = 128 << 10

type server struct {
	fd        int
	h         *hub
	peersDir  string
	statsPath string
	started   time.Time
	tick      time.Duration
}

func listen(sockPath string) (int, error) {
	fd, err := syscall.Socket(syscall.AF_UNIX, syscall.SOCK_DGRAM|syscall.SOCK_CLOEXEC, 0)
	if err != nil {
		return -1, err
	}
	// A previous hub's socket file (it died, or was restarted) is replaced.
	if err := os.Remove(sockPath); err != nil && !errors.Is(err, os.ErrNotExist) {
		syscall.Close(fd)
		return -1, err
	}
	if err := syscall.Bind(fd, &syscall.SockaddrUnix{Name: sockPath}); err != nil {
		syscall.Close(fd)
		return -1, fmt.Errorf("bind %s: %w", sockPath, err)
	}
	_ = syscall.SetsockoptInt(fd, syscall.SOL_SOCKET, syscall.SO_RCVBUF, 4<<20) // capped by rmem_max
	return fd, nil
}

// send delivers frame to peer path on that peer's own socket, never blocking.
func (s *server) send(path string, frame []byte) {
	p := s.h.peers[path]
	if p == nil {
		return
	}
	if p.fd < 0 {
		fd, err := syscall.Socket(syscall.AF_UNIX, syscall.SOCK_DGRAM|syscall.SOCK_CLOEXEC, 0)
		if err != nil {
			s.h.c.sendErr++
			return
		}
		_ = syscall.SetsockoptInt(fd, syscall.SOL_SOCKET, syscall.SO_SNDBUF, 4<<20) // capped by wmem_max
		p.fd = fd
	}
	err := syscall.Sendto(p.fd, frame, syscall.MSG_DONTWAIT, &syscall.SockaddrUnix{Name: path})
	switch {
	case err == nil:
		p.tx++
		s.h.c.copies++
	case errors.Is(err, syscall.EAGAIN), errors.Is(err, syscall.ENOBUFS):
		p.full++
		s.h.c.dropFull++
	case errors.Is(err, syscall.ECONNREFUSED), errors.Is(err, syscall.ENOENT):
		p.gone++
		s.h.c.dropGone++
	default:
		s.h.c.sendErr++
	}
}

func (s *server) maintain(now time.Time) {
	removed, added, gone := s.h.sync(scanDir(s.peersDir), now)
	for _, p := range removed {
		if p.fd >= 0 {
			syscall.Close(p.fd)
		}
	}
	for _, a := range added {
		log.Printf("peer + %s", filepath.Base(a))
	}
	for _, g := range gone {
		log.Printf("peer - %s", filepath.Base(g))
	}
	if s.statsPath != "" {
		if err := s.writeStats(now); err != nil {
			log.Printf("stats: %v", err)
		}
	}
}

// writeStats replaces the stats file atomically: hub-wide counters, then one
// line per peer.
func (s *server) writeStats(now time.Time) error {
	c := s.h.c
	b := fmt.Appendf(nil, "pid %d\nstarted %s\nupdated %s\npeers %d\nmacs %d\n",
		os.Getpid(), s.started.UTC().Format(time.RFC3339), now.UTC().Format(time.RFC3339),
		len(s.h.peers), len(s.h.macs))
	b = fmt.Appendf(b, "rx_frames %d\nrx_bytes %d\nunicast %d\nflooded %d\ncopies %d\n",
		c.rxFrames, c.rxBytes, c.unicast, c.flooded, c.copies)
	b = fmt.Appendf(b, "drop_full %d\ndrop_gone %d\ndrop_runt %d\ndrop_local %d\nsend_err %d\n",
		c.dropFull, c.dropGone, c.dropRunt, c.dropLocal, c.sendErr)
	for _, path := range sortedKeys(s.h.peers) {
		p := s.h.peers[path]
		b = fmt.Appendf(b, "peer %s rx=%d tx=%d full=%d gone=%d\n", filepath.Base(path), p.rx, p.tx, p.full, p.gone)
	}
	tmp := s.statsPath + ".tmp"
	if err := os.WriteFile(tmp, b, 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, s.statsPath)
}

// serve runs until stop is closed (never, for the real hub) or a socket error
// that is not a timeout or an interrupt.
func (s *server) serve(stop <-chan struct{}) error {
	tv := syscall.NsecToTimeval(s.tick.Nanoseconds())
	if err := syscall.SetsockoptTimeval(s.fd, syscall.SOL_SOCKET, syscall.SO_RCVTIMEO, &tv); err != nil {
		return err
	}
	buf := make([]byte, maxFrame)
	last := time.Time{}
	for {
		select {
		case <-stop:
			return nil
		default:
		}
		n, from, err := syscall.Recvfrom(s.fd, buf, 0)
		now := time.Now()
		switch {
		case err == nil:
			src := ""
			if ua, ok := from.(*syscall.SockaddrUnix); ok {
				src = ua.Name
			}
			for _, t := range s.h.targets(src, buf[:n], now) {
				s.send(t, buf[:n])
			}
		case errors.Is(err, syscall.EAGAIN), errors.Is(err, syscall.EINTR):
		default:
			return fmt.Errorf("recv: %w", err)
		}
		if now.Sub(last) >= s.tick {
			s.maintain(now)
			last = now
		}
	}
}

func sortedKeys(m map[string]*peer) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}

func main() {
	sock := flag.String("sock", "", "hub socket path (required)")
	peers := flag.String("peers", "", "directory holding the VM NICs' sockets (default: <dir of -sock>/peers)")
	stats := flag.String("stats", "", "stats file, rewritten every second (default: <dir of -sock>/stats)")
	pidfile := flag.String("pidfile", "", "write the hub's pid here")
	macAge := flag.Duration("mac-age", 2*time.Minute, "forget a learned MAC after this much silence")
	peerAge := flag.Duration("peer-age", 5*time.Minute, "drop a peer outside the peers dir after this much silence")
	flag.Parse()
	if *sock == "" {
		flag.Usage()
		os.Exit(2)
	}
	dir := filepath.Dir(*sock)
	if *peers == "" {
		*peers = filepath.Join(dir, "peers")
	}
	if *stats == "" {
		*stats = filepath.Join(dir, "stats")
	}
	log.SetFlags(log.LstdFlags | log.LUTC)
	log.SetPrefix(fmt.Sprintf("lanhub[%d] ", os.Getpid()))

	fd, err := listen(*sock)
	if err != nil {
		log.Fatal(err)
	}
	if *pidfile != "" {
		if err := os.WriteFile(*pidfile, fmt.Appendf(nil, "%d\n", os.Getpid()), 0o644); err != nil {
			log.Fatal(err)
		}
	}
	s := &server{fd: fd, h: newHub(*macAge, *peerAge), peersDir: *peers, statsPath: *stats,
		started: time.Now(), tick: time.Second}
	log.Printf("listening on %s, peers in %s", *sock, *peers)
	s.maintain(time.Now())
	log.Fatal(s.serve(nil))
}
