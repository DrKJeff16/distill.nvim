package main

import (
	"fmt"
	"log"
)

func run(err error) string {
	logger.Info("starting") // @log
	logger.Debugf("x=%d", 1) // @log
	log.Printf("y") // @log
	slog.Warn( // @log
		"multi",
		"k", 1,
	)
	zlog.Info().Str("a", "b").Msg("zero") // @log
	msg := err.Error()
	x := compute(1)
	fmt.Println("print") // @print
	return msg + fmt.Sprint(x)
}
