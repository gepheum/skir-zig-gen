#!/bin/bash

set -e

npm i
npm run lint:fix
npm run format
npm run build
npm run test
cd e2e-test
zig fmt src/root.zig src/skir_client.zig build.zig
zig build test -Doptimize=Debug
zig build test -Doptimize=ReleaseSafe
zig build-lib src/skir_client.zig -femit-docs=docs
rm -f libskir_client.a
cd ..

# cd e2e-test/docs && python3 -m http.server
