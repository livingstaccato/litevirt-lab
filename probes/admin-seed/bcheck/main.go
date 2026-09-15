package main

import (
	"fmt"
	"os"

	"golang.org/x/crypto/bcrypt"
)

func main() {
	if len(os.Args) != 3 {
		fmt.Fprintln(os.Stderr, "usage: bcheck <bcrypt-hash> <password>")
		os.Exit(2)
	}
	if err := bcrypt.CompareHashAndPassword([]byte(os.Args[1]), []byte(os.Args[2])); err != nil {
		fmt.Println("NO")
		os.Exit(1)
	}
	fmt.Println("YES")
}
