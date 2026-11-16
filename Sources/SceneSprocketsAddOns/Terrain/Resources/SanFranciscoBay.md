# SanFranciscoBay.png

Elevation of the Golden Gate area: northern San Francisco, the Marin Headlands, Sausalito, Angel Island and Alcatraz.

- Source: USGS 3D Elevation Program (3DEP) bare-earth DEM, via the 3DEPElevation ImageServer `exportImage`
  endpoint. USGS data is a US Government work and in the public domain.
- Area: a 16,384 m square in UTM zone 10N (EPSG:32610), easting 539328...555712, northing 4178899...4195283,
  centered near 37.83° N, 122.46° W. North is at the top.
- Pixels: 2048 x 2048, 16-bit grayscale, 8 m per pixel. Value / 65535 x 1100 m - 120 m is the height, so it is true scale
  with the default `heightScale` (1100) and `worldSize` (16384). The bay floor (down to about -115 m) is kept;
  `HeightSource.sanFranciscoBay()` draws it flat at 0 with a height floor, applied after filtering. The
  highest point is about 341 m.
