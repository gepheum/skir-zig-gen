#!/bin/bash

set -e

npm i
npm run lint:fix
npm run format
npm run build
npm run test
cd e2e-test
zig fmt src/root.zig build.zig
zig build test -Doptimize=Debug
zig build test -Doptimize=ReleaseSafe
cd ..

# lsof -ti :8000 | xargs kill
# cd e2e-test/docs && python3 -m http.server
