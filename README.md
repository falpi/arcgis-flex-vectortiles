<p align="center"><img src="assets/logo-wordmark.svg" alt="arcgis-flex-vectortiles" width="640"></p>

# arcgis-flex-vectortiles

An extension of the ArcGIS API for Flex 3.7: `org.falpi.ags.layers.VectorTileLayer`.

> Independent project, not affiliated with or endorsed by Esri. ArcGIS is a trademark of Esri.


A layer for the `Map` of the ArcGIS API for Flex 3.7 that draws **vector basemaps**
(Mapbox Vector Tiles in PBF + Mapbox GL style). It was built to replace
`ArcGISTiledMapServiceLayer` now that Esri's raster basemaps are being phased out.

The same class accepts:

| Source | Example `url` |
|---|---|
| Esri VectorTileServer | `https://basemaps.arcgis.com/arcgis/rest/services/World_Basemap_v2/VectorTileServer` |
| ArcGIS item with a style (custom styles too) | `https://www.arcgis.com/sharing/rest/content/items/<id>` |
| Any Mapbox GL style (MapLibre, MapTiler, OpenMapTiles, Mapbox…) | `https://tiles.openfreemap.org/styles/liberty`, `mapbox://styles/...` |

The source type is detected from the content of the response; there is no need to specify it.

## Usage

```xml
<esri:Map>
    <!-- before: <esri:ArcGISTiledMapServiceLayer url=".../World_Street_Map/MapServer"/> -->
    <falpi:VectorTileLayer
        url="https://basemaps.arcgis.com/arcgis/rest/services/World_Basemap_v2/VectorTileServer"
        proxyURL="https://my-server/proxy/proxy.ashx"/>
</esri:Map>
```

with `xmlns:falpi="http://falpi.org/ags"` (or `xmlns:falpi="org.falpi.ags.layers.*"`).
From ActionScript: `import org.falpi.ags.layers.VectorTileLayer;` and `new VectorTileLayer(url, proxyURL, token)`.

Just add `bin/arcgis-flex-vectortiles.swc` to the library path of the application,
which must already link the Flex SDK 4.6 and the ArcGIS 3.7 SWC.

Complete example with a basemap selector: [examples/VectorTileDemo.mxml](examples/VectorTileDemo.mxml).

### Properties

| Property | Description |
|---|---|
| `url` | Service, item or style (see above). Changing it after the layer has loaded reloads the basemap. |
| `proxyURL` | Proxy page; requests become `proxyURL?URL`, as for the other Esri layers. **Required in the browser**, see below. |
| `token` | ArcGIS token or API key, appended to every request. |
| `tokenParameter` | Name of the token parameter: `token` (default), `access_token` (Mapbox), `key` (MapTiler). |
| `style` | Mapbox GL style (Object or JSON string) that replaces the one published at the URL. |
| `tilingScheme` | `arcgis` (default): the `Map` gets the 24 levels of the classic raster basemaps, so `map.level` and the scales stay the same as before. `service`: levels of the vector service (512 px tiles, one level fewer at the same scale). |
| `labelsVisible` | Shows or hides labels and icons. |
| `minimumHaloWidth` | Halo width in pixels given to the labels whose style has none, to keep them readable on busy backgrounds (default 1.5). 0 draws them as the style says. |
| `minimumHaloColor` | Color of that halo as `0xRRGGBB`. Not set (the default): white behind dark text, black behind light text. |
| `minimumHaloAlpha` | Opacity of that halo, 0 to 1 (default 0.8). |
| `maxConnections` | Parallel HTTP requests (default 6). |
| `styleDefinition` | The parsed style, read-only. |
| `diagnostics` | Shows a box at the top left of the map with the player version, the real frame rate, the tiles being loaded and where the time of the last update went. Meant for reporting performance problems. |
| `updateTimings` | The timings of the last completed update as text (tiles, drawing, label placement, total), read-only. |

Inherited from `TiledMapServiceLayer`/`Layer`: `tileInfo`, `fullExtent`, `initialExtent`,
`spatialReference`, `copyright` (taken from the service), `visible`, `alpha`, `minScale`, `maxScale`…

### Events

`load`, `loadError`, `updateStart`, `updateEnd` (dispatched once the labels are drawn too),
`isInScaleRangeChange`, plus `fault` (`FaultEvent`) if the service or the style cannot be loaded.

## Proxy and crossdomain

Flash Player reads binary data from another domain only if that domain publishes a
`crossdomain.xml`. Esri's vector basemap servers do not publish one
(`basemaps.arcgis.com`, `www.arcgis.com`, `cdn.arcgis.com`), so in production you need a proxy
on the same server as the Flex application, for example Esri's
[resource-proxy](https://github.com/Esri/resource-proxy). The proxy must:

- allow at least `basemaps.arcgis.com`, `www.arcgis.com` and `cdn.arcgis.com`
  (plus the hosts of any non-Esri styles);
- return binary data unaltered (tiles may arrive gzip-compressed: the layer decompresses them).

The policy must come directly from the requested URL: Flash ignores a `crossdomain.xml`
reached through a redirect to another scheme or host, even if its content is correct.
In that case the layer gets `#2048 Security sandbox violation` and the proxy must be used.
Raster basemap tiles are not subject to this constraint because they are images: Flash displays
them even without a policy, whereas data (style, metadata, PBF tiles, glyphs, sprites) must be read.

## Style coverage

| Element | Status |
|---|---|
| `background`, `fill`, `line`, `circle` | Supported: colors, opacity, `fill-pattern`, `line-dasharray`, `line-offset`, `line-blur`, cap/join, `*-translate` |
| `line-pattern` | Supported: the image follows the line segment by segment, with the joins filled |
| `symbol` | Labels (SDF glyphs with halo), text along lines, line wrapping, anchors, offsets, `text-transform`, sprite icons (SDF icons in `icon-color`), rotation, collisions with priority by style order and `symbol-sort-key` |
| Sprites | A single sheet or several (`sprite` as an array of `{id, url}`, images named `id:name`) |
| Filters | Legacy syntax and expressions |
| Functions | Legacy `stops` (zoom, property, zoom+property) and expressions (`match`, `case`, `interpolate`, `step`, `coalesce`, `let`/`var`, math, strings, colors…) |
| `fill-extrusion` | Drawn flat (footprint) |
| `line-gap-width` | Approximated with a single line |
| `raster`, `hillshade`, `heatmap`, terrain, sky | Ignored |
| `icon-text-fit`, `text-variable-anchor` | Not implemented (not used by the Esri, OpenFreeMap and VersaTiles styles) |
| Complex scripts (Arabic, Indic, bidi) | Not supported (Latin, Greek, Cyrillic, CJK are) |

## Known limitations and untested areas

- **Projection**: only Web Mercator (102100/3857) has been tested. The code for Esri services in
  other projections (levels taken from the service `tileInfo`) has not been tested.
- **`wrapAround180`** is not supported (the world is not repeated across the antimeridian).
- **Map rotation** (`mapRotation`) has not been tested.
- Labels are placed during a drag, with the button still held: every 0.15 s while the map moves (less
  often when placing them is slow: at most an eighth of the time) and when it stays still for a moment.
  These placements only add the labels of the area brought into view, next to the ones already shown;
  on release all of them are placed again, so a few may move.
  During a zoom they are hidden and come back at the new scale.
- CPU rendering, spread over several frames: a few milliseconds per tile with the Esri styles in a release
  build, more with styles that have hundreds of layers (e.g. OpenStreetMap Shortbread).
- **Measure performance on release builds**: with a debug SWF or the debugger Flash Player the same code
  runs many times slower (about 30 times in our measurements).
- Esri **Basemap Styles service v2** (`basemapstyles-api.arcgis.com`, with API key) has not been tested;
  tested: the `World_Basemap_v2` VectorTileServer and Esri's public items (Street, Navigation,
  Street Night, Light/Dark Gray Canvas with their reference layers).
- Esri's "Canvas" basemaps have their labels in a separate item ("Reference"): add it
  as a second `VectorTileLayer` above the base (see the example).

## Layout

```
src/org/falpi/ags/layers/
  VectorTileLayer.as             the component (Map integration, tiles, frames, labels)
src/org/falpi/ags/layers/vectorTiles/
  source/                        service / item / style / TileJSON resolution
  style/                         Mapbox GL style: layers, properties, filters, expressions, colors
  mvt/, pbf/                     Protocol Buffers and Mapbox Vector Tile decoders
  render/                        CPU tile renderer and sprites
  labels/                        SDF glyphs, text shaping, collisions, placement
  net/, util/                    loading with proxy/token/gzip, URLs
examples/                        example application
src/manifest.xml                 MXML namespace http://falpi.org/ags
libs/agslib-3.7-2014-11-06.swc   ArcGIS API for Flex (linked externally)
```

## Build

**Flash Builder 4.7**: *File > Import > General > Existing Projects into Workspace* and select
this folder. It is a Flex library project (SDK 4.6) that produces `bin/arcgis-flex-vectortiles.swc`;
the Flex framework and `libs/agslib-3.7-2014-11-06.swc` are linked externally.
The ArcGIS API for Flex SWC is not in the repository: copy it into `libs/` (see [libs/README.md](libs/README.md)).
The compiled SWC of this extension is available in the repository Releases.

The example `examples/VectorTileDemo.mxml` is compiled in a Flex application project that links
the SWC (or the sources in `src/`) and the ArcGIS SWC; the proxy page is passed with the `proxyURL` FlashVar.

## License

Distributed under the [Apache 2.0](LICENSE) license. Copyright 2026 falpi.

The ArcGIS API for Flex, required to compile and use the layer, belongs to Esri and has its own license:
it is neither included in nor covered by this license.
