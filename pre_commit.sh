#!/bin/bash

set -e

npm i
npm run lint:fix
npm run format
npm run build
npm run test
cd e2e-test && zig fmt src/root.zig src/skir_client.zig build.zig && zig build test && cd ..
