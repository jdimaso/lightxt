# DuckDB runtime

LighTxt vendors the official DuckDB 1.4.5 LTS universal macOS library archive
to provide bounded, read-only Parquet queries without a runtime download.

- Source: https://github.com/duckdb/duckdb/releases/tag/v1.4.5
- Archive: `libduckdb-osx-universal.zip`
- Vendored filename: `libduckdb-osx-universal-v1.4.5.zip`
- SHA-256: `33f840404e3b420600936d5b59d342680aa4af41cc06d9a5589711e43cd75766`
- Architectures: `arm64`, `x86_64`
- License: MIT; the bundled copy is at `LighTxt/DuckDB-LICENSE.txt`
- Vendored dependency notices: `ThirdParty/DuckDB/Licenses/`, copied without
  modification from the v1.4.5 source tree

The deterministic SHA-256 over the sorted per-file SHA-256 listing in the
vendored license directory is
`d01087ae16feea36d5ae4a3d80a48fc683bb043cb3e9f147a63088b7498d623a`.

The Xcode build extracts only `libduckdb.dylib` into the app's Frameworks
directory, signs that nested code with the active app identity, and copies the
license directory into the app's Resources. Headers and the source ZIP are not
copied into the product.
