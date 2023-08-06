PROJ=$(shell realpath $$PWD/../../../..)
ENV=env GOPATH=$(PROJ)
CLI=$(ENV) easyjson -all

JSON_SRC_FILES=\
	structs.go

JSON_OUT_FILES:=$(JSON_SRC_FILES:%.go=%_easyjson.go)

.PHONY: json
json: $(JSON_OUT_FILES)

%_easyjson.go: %.go
	$(CLI) $^

.PHONY: fmt
fmt:
	$(ENV) goimports -w $$(find . -maxdepth 1 -path ./vendor -prune -o -name "*.go" -print)

.PHONY: test
test:
	go test ./...
