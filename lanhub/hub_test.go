package main

import (
	"bytes"
	"os"
	"path/filepath"
	"reflect"
	"syscall"
	"testing"
	"time"
)

var (
	macA  = mac{0x52, 0x54, 0, 0x77, 1, 1}
	macB  = mac{0x52, 0x54, 0, 0x77, 1, 2}
	macC  = mac{0x52, 0x54, 0, 0x77, 1, 3}
	bcast = mac{0xff, 0xff, 0xff, 0xff, 0xff, 0xff}
	mcast = mac{0x01, 0x00, 0x5e, 0, 0, 1}
)

func frame(dst, src mac, payload string) []byte {
	f := append(append(append([]byte{}, dst[:]...), src[:]...), 0x08, 0x00)
	return append(f, payload...)
}

func threePeers() *hub {
	h := newHub(time.Minute, time.Minute)
	h.sync(map[string]bool{"a": true, "b": true, "c": true}, time.Unix(0, 0))
	return h
}

func TestFloodNeverEchoes(t *testing.T) {
	h := threePeers()
	now := time.Unix(100, 0)
	for _, dst := range []mac{bcast, mcast, macC} { // broadcast, multicast, unknown unicast
		if got := h.targets("a", frame(dst, macA, "x"), now); !reflect.DeepEqual(got, []string{"b", "c"}) {
			t.Errorf("frame from a to %x went to %v, want [b c]", dst, got)
		}
	}
}

func TestLearnedUnicastGoesToOnePeer(t *testing.T) {
	h := threePeers()
	now := time.Unix(100, 0)
	h.targets("a", frame(bcast, macA, "arp who-has"), now)
	if got := h.targets("b", frame(macA, macB, "reply"), now); !reflect.DeepEqual(got, []string{"a"}) {
		t.Fatalf("b -> learned macA went to %v, want [a]", got)
	}
	if got := h.targets("c", frame(macB, macC, "x"), now); !reflect.DeepEqual(got, []string{"b"}) {
		t.Fatalf("c -> learned macB went to %v, want [b]", got)
	}
	if h.c.unicast != 2 || h.c.flooded != 1 {
		t.Fatalf("unicast=%d flooded=%d, want 2 and 1", h.c.unicast, h.c.flooded)
	}
}

func TestFrameForSendersOwnPortIsDropped(t *testing.T) {
	h := threePeers()
	now := time.Unix(100, 0)
	h.targets("a", frame(bcast, macA, "x"), now)
	h.targets("a", frame(bcast, macB, "x"), now) // a second MAC behind a (a bridged guest)
	if got := h.targets("a", frame(macA, macB, "x"), now); len(got) != 0 {
		t.Fatalf("frame from a for a MAC behind a went to %v, want nowhere", got)
	}
	if h.c.dropLocal != 1 {
		t.Fatalf("dropLocal=%d, want 1", h.c.dropLocal)
	}
}

func TestLearnedMACAgesOutAndMoves(t *testing.T) {
	h := threePeers()
	t0 := time.Unix(100, 0)
	h.targets("a", frame(bcast, macA, "x"), t0)
	if got := h.targets("b", frame(macA, macB, "x"), t0.Add(2*time.Minute)); !reflect.DeepEqual(got, []string{"a", "c"}) {
		t.Fatalf("after macAge, b -> macA went to %v, want a flood [a c]", got)
	}
	// A guest migrated from a to c announces itself from c: the MAC moves.
	t1 := t0.Add(3 * time.Minute)
	h.targets("c", frame(bcast, macA, "rarp"), t1)
	if got := h.targets("b", frame(macA, macB, "x"), t1); !reflect.DeepEqual(got, []string{"c"}) {
		t.Fatalf("after the move, b -> macA went to %v, want [c]", got)
	}
}

func TestRuntIsDropped(t *testing.T) {
	h := threePeers()
	if got := h.targets("a", []byte{1, 2, 3}, time.Unix(1, 0)); got != nil || h.c.dropRunt != 1 {
		t.Fatalf("runt went to %v (dropRunt=%d)", got, h.c.dropRunt)
	}
}

func TestSyncDropsVanishedPeers(t *testing.T) {
	h := threePeers()
	t0 := time.Unix(100, 0)
	h.targets("x", frame(bcast, macC, "x"), t0) // x is not in the dir, but spoke
	h.targets("b", frame(bcast, macB, "x"), t0)
	_, _, gone := h.sync(map[string]bool{"a": true, "b": true}, t0.Add(time.Second))
	if !reflect.DeepEqual(gone, []string{"c"}) {
		t.Fatalf("gone=%v, want [c] (silent and out of the dir); x was heard recently", gone)
	}
	_, _, gone = h.sync(map[string]bool{"a": true}, t0.Add(2*time.Minute))
	if !reflect.DeepEqual(gone, []string{"b", "x"}) {
		t.Fatalf("gone=%v, want [b x] once silent past peerAge", gone)
	}
	if _, ok := h.macs[macB]; ok {
		t.Fatal("macB still learned behind a removed peer")
	}
}

// TestSocketsEndToEnd runs the real server over Unix datagram sockets: a
// broadcast reaches every other peer but not the sender, a learned unicast
// reaches only its peer, and a peer that never reads (its queue fills) and a
// peer whose VM is gone (stale socket file) cost nobody else a frame.
func TestSocketsEndToEnd(t *testing.T) {
	dir, err := os.MkdirTemp("", "lh") // short: sun_path is 108 bytes
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(dir) })
	peers := filepath.Join(dir, "peers")
	if err := os.Mkdir(peers, 0o700); err != nil {
		t.Fatal(err)
	}
	hubSock := filepath.Join(dir, "hub.sock")
	fd, err := listen(hubSock)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { syscall.Close(fd) })

	bind := func(name string) int {
		pfd, err := syscall.Socket(syscall.AF_UNIX, syscall.SOCK_DGRAM, 0)
		if err != nil {
			t.Fatal(err)
		}
		if err := syscall.Bind(pfd, &syscall.SockaddrUnix{Name: filepath.Join(peers, name+".sock")}); err != nil {
			t.Fatal(err)
		}
		tv := syscall.NsecToTimeval((300 * time.Millisecond).Nanoseconds())
		syscall.SetsockoptTimeval(pfd, syscall.SOL_SOCKET, syscall.SO_RCVTIMEO, &tv)
		return pfd
	}
	a, b, c, stuck := bind("a"), bind("b"), bind("c"), bind("stuck")
	dead := bind("dead")
	syscall.Close(dead) // the socket file stays, like a stopped VM's
	for _, f := range []int{a, b, c, stuck} {
		t.Cleanup(func() { syscall.Close(f) })
	}

	s := &server{fd: fd, h: newHub(time.Minute, time.Minute), peersDir: peers, started: time.Now(), tick: 50 * time.Millisecond}
	s.maintain(time.Now()) // learn the peers dir before the first frame
	stop := make(chan struct{})
	done := make(chan error, 1)
	go func() { done <- s.serve(stop) }()
	stopped := false
	halt := func() {
		if !stopped {
			stopped = true
			close(stop)
			select {
			case err := <-done:
				if err != nil {
					t.Error(err)
				}
			case <-time.After(5 * time.Second):
				t.Fatal("the hub did not stop: it is blocked on a send")
			}
		}
	}
	defer halt()

	tx := func(from int, f []byte) {
		for {
			err := syscall.Sendto(from, f, 0, &syscall.SockaddrUnix{Name: hubSock})
			if err == syscall.EINTR {
				continue
			}
			if err != nil {
				t.Fatal(err)
			}
			return
		}
	}
	rx := func(on int) []byte {
		buf := make([]byte, maxFrame)
		for {
			// Go's preemption signal interrupts a recv that has SO_RCVTIMEO set
			// with EINTR, SA_RESTART or not; only a timeout means "nothing came".
			n, _, err := syscall.Recvfrom(on, buf, 0)
			if err == syscall.EINTR {
				continue
			}
			if err != nil {
				return nil
			}
			return buf[:n]
		}
	}

	hello := frame(bcast, macA, "hello")
	tx(a, hello)
	if got := rx(b); !bytes.Equal(got, hello) {
		t.Fatalf("b got %q, want the broadcast", got)
	}
	if got := rx(c); !bytes.Equal(got, hello) {
		t.Fatalf("c got %q, want the broadcast", got)
	}
	if got := rx(a); got != nil {
		t.Fatalf("the sender got its own broadcast back: %q", got)
	}

	// Fill stuck's queue (it never reads), with jumbo frames.
	jumbo := frame(bcast, macC, string(bytes.Repeat([]byte{'j'}, 9000)))
	for range 1000 {
		tx(c, jumbo)
		if !bytes.Equal(rx(a), jumbo) || !bytes.Equal(rx(b), jumbo) { // a and b keep reading
			t.Fatal("a reading peer lost a jumbo frame while another peer was stuck")
		}
	}
	reply := frame(macA, macB, "reply")
	tx(b, reply)
	if got := rx(a); !bytes.Equal(got, reply) {
		t.Fatalf("a got %q, want b's unicast reply", got)
	}
	if got := rx(c); got != nil {
		t.Fatalf("c got a unicast meant for a: %q", got)
	}
	halt() // the counters belong to the serving goroutine until it stops
	if s.h.c.dropFull == 0 || s.h.c.dropGone == 0 {
		t.Fatalf("dropFull=%d dropGone=%d: the stuck and dead peers should have dropped, not blocked", s.h.c.dropFull, s.h.c.dropGone)
	}
}
