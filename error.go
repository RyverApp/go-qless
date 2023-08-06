package qless

import (
	"regexp"
	"strconv"
	"strings"
)

var errRegEx = regexp.MustCompile(`^ERR.*user_script:(?P<line>\d+):\s*(?P<area>[\w.]+)\(\):\s*(?P<message>.*)`)

type CommandError struct {
	inner   error
	Line    int
	Area    string
	Message string
}

func (e *CommandError) Error() string {
	return e.inner.Error()
}

func parseError(in error) error {
	if in == nil {
		return nil
	}

	m := errRegEx.FindStringSubmatch(in.Error())
	if len(m) == 4 {
		line, _ := strconv.Atoi(m[1])
		return &CommandError{
			inner:   in,
			Line:    line,
			Area:    m[2],
			Message: m[3],
		}
	}
	return in
}

func IsJobLost(err error) bool {
	c, ok := err.(*CommandError)
	return ok && strings.Contains(c.Message, "given out to another worker")
}
