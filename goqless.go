// reference: https://github.com/seomoz/qless-py
package qless

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"strconv"

	"github.com/gomodule/redigo/redis"
	"github.com/mailru/easyjson"
)

// type Opts map[string]interface{}

// func (o Opts) Get(name string, dfault interface{}) interface{} {
//   if v, ok := o[name]; ok {
//     return v
//   }
//   return dfault
// }

// represents a string slice with special json unmarshalling
type StringSlice []string

var workerNameStr string

func init() {
	hn, err := os.Hostname()
	if err != nil {
		hn = os.Getenv("HOSTNAME")
	}

	if hn == "" {
		hn = "localhost"
	}

	workerNameStr = fmt.Sprintf("%s-%d", hn, os.Getpid())
}

func (s *StringSlice) UnmarshalJSON(data []byte) error {
	// because tables and arrays are equal in LUA,
	// an empty array would be presented as "{}".
	if bytes.Equal(data, []byte("{}")) {
		*s = []string{}
		return nil
	}

	var str []string
	err := json.Unmarshal(data, &str)
	if err != nil {
		return err
	}

	*s = str
	return nil
}

// marshals a value. if the value happens to be
// a string or []byte, just return it.
func marshal(i interface{}) (r []byte) {
	var err error
	if m, ok := i.(easyjson.Marshaler); ok {
		r, err = easyjson.Marshal(m)
	} else {
		r, err = json.Marshal(i)
	}

	if err != nil {
		return nil
	}
	return
}

func unmarshal(data []byte, v interface{}) error {
	if m, ok := v.(easyjson.Unmarshaler); ok {
		return easyjson.Unmarshal(data, m)
	}

	return json.Unmarshal(data, v)
}

// Bool is a helper that converts a command reply to a boolean. If err is not
// equal to nil, then Bool returns false, err. Otherwise Bool converts the
// reply to boolean as follows:
//
//  Reply type      Result
//  integer         value != 0, nil
//  bulk            strconv.ParseBool(reply) or r != "False", nil
//  nil             false, ErrNil
//  other           false, error
func Bool(reply interface{}, err error) (bool, error) {
	if err != nil {
		return false, err
	}
	switch reply := reply.(type) {
	case int64:
		return reply != 0, nil
	case []byte:
		r := string(reply)
		b, err := strconv.ParseBool(r)
		if err != nil {
			return r != "False", nil
		}
		return b, err
	case nil:
		return false, redis.ErrNil
	case redis.Error:
		return false, reply
	}
	return false, fmt.Errorf("redigo: unexpected type for Bool, got type %T", reply)
}
