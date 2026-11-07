# The home world's relief

`earth_relief.bin` is Earth's relief, 2048 x 1024 cells (360 / 2048 degrees, about 19.5 km
at the equator), metres, row 0 the northernmost. Format: magic `VXPL`, version 1, width,
height (u32 little-endian), then the elevations (i16 little-endian) as a zlib stream
(`common/planet/relief.odin`).

- **Source:** NOAA National Geophysical Data Center, *ETOPO5: 5-minute gridded elevation
  data* (1988), ice surface. 5 arc-minutes, big-endian i16, row 0 at 90 N, column 0 at 0 E.
  The data is used as ETOPO5 (not ETOPO 2022).
- **URL:** https://www.ngdc.noaa.gov/mgg/global/relief/ETOPO5/TOPO/ETOPO5/ETOPO5.DAT
- **SHA-256 of the source:** `471d3dd534144aa9a6551fe3e76320a06a45dade6fd8d45f7d6ad981d59f93c3`
- **Licence:** public domain (a work of the US government).
- **Import:** download the source to a scratch folder, then
  `./build.sh planet import <path>/ETOPO5.DAT`. The source is never committed; the tool
  averages it (each cell the area-weighted mean of the source cells it covers) and rewrites
  this file byte for byte.

# The home world's climate

`earth_climate.bin` is Earth's climate grid and rivers as `planet_build` and `rivers_build`
make them from `earth_relief.bin`, so the game decodes them (`common/planet/climate_file.odin`)
instead of computing them at start (seconds at -o:minimal). Format: magic `VXCL`, version,
the model's code version, the relief's hash, width, height, then every array of the model
delta coded by byte plane and run-length coded.

- **Write:** `./build.sh planet climate` (after a change to the relief or to any code the
  climate model runs, and bump `CLIMATE_MODEL_VERSION` with the latter).
- **Stale:** `test_earth_climate_file` fails when the file is not exactly what the model
  builds from the committed relief. A file the game cannot use (another relief or version)
  falls back to building the model.
