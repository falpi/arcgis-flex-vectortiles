# arcgis-flex-vectortiles

Estensione dell'ArcGIS API for Flex 3.7: `org.falpi.ags.layers.VectorTileLayer`.

> Progetto indipendente, non affiliato né supportato da Esri. ArcGIS è un marchio di Esri.


Layer per la `Map` dell'ArcGIS API for Flex 3.7 che disegna **basemap vettoriali**
(tile Mapbox Vector Tile in PBF + stile Mapbox GL). Nasce per sostituire
`ArcGISTiledMapServiceLayer` ora che le basemap raster di Esri vanno verso la dismissione.

La stessa classe accetta:

| Sorgente | Esempio di `url` |
|---|---|
| VectorTileServer Esri | `https://basemaps.arcgis.com/arcgis/rest/services/World_Basemap_v2/VectorTileServer` |
| Item ArcGIS con stile (anche personalizzato) | `https://www.arcgis.com/sharing/rest/content/items/<id>` |
| Stile Mapbox GL qualsiasi (MapLibre, MapTiler, OpenMapTiles, Mapbox…) | `https://tiles.openfreemap.org/styles/liberty`, `mapbox://styles/...` |

Il tipo di sorgente è riconosciuto dal contenuto della risposta, non serve indicarlo.

## Uso

```xml
<esri:Map>
    <!-- prima: <esri:ArcGISTiledMapServiceLayer url=".../World_Street_Map/MapServer"/> -->
    <falpi:VectorTileLayer
        url="https://basemaps.arcgis.com/arcgis/rest/services/World_Basemap_v2/VectorTileServer"
        proxyURL="https://my-server/proxy/proxy.ashx"/>
</esri:Map>
```

con `xmlns:falpi="http://falpi.org/ags"` (oppure `xmlns:falpi="org.falpi.ags.layers.*"`).
Da ActionScript: `import org.falpi.ags.layers.VectorTileLayer;` e `new VectorTileLayer(url, proxyURL, token)`.

Basta aggiungere `bin/arcgis-flex-vectortiles.swc` alla library path dell'applicazione,
che deve già linkare il Flex SDK 4.6 e lo SWC ArcGIS 3.7.

Esempio completo con selettore delle basemap: [examples/VectorTileDemo.mxml](examples/VectorTileDemo.mxml).

### Proprietà

| Proprietà | Descrizione |
|---|---|
| `url` | Servizio, item o stile (vedi sopra). Cambiarla a layer caricato ricarica la basemap. |
| `proxyURL` | Pagina proxy; le richieste diventano `proxyURL?URL`, come per gli altri layer Esri. **Nel browser è necessaria**, vedi sotto. |
| `token` | Token ArcGIS o API key, aggiunto a tutte le richieste. |
| `tokenParameter` | Nome del parametro del token: `token` (default), `access_token` (Mapbox), `key` (MapTiler). |
| `style` | Stile Mapbox GL (Object o stringa JSON) che sostituisce quello pubblicato all'URL. |
| `tilingScheme` | `arcgis` (default): la `Map` riceve i 24 livelli delle basemap raster classiche, quindi `map.level` e le scale restano quelli di prima. `service`: livelli del servizio vettoriale (tile 512 px, un livello in meno a parità di scala). |
| `labelsVisible` | Mostra o nasconde etichette e icone. |
| `maxConnections` | Richieste HTTP in parallelo (default 6). |
| `styleDefinition` | Lo stile analizzato, in sola lettura. |

Ereditate da `TiledMapServiceLayer`/`Layer`: `tileInfo`, `fullExtent`, `initialExtent`,
`spatialReference`, `copyright` (preso dal servizio), `visible`, `alpha`, `minScale`, `maxScale`…

### Eventi

`load`, `loadError`, `updateStart`, `updateEnd` (emesso quando anche le etichette sono
disegnate), `isInScaleRangeChange`, più `fault` (`FaultEvent`) se servizio o stile non si caricano.

## Proxy e crossdomain

Il Flash Player legge dati binari da un altro dominio solo se quel dominio pubblica un
`crossdomain.xml`. I server delle basemap vettoriali Esri non lo pubblicano
(`basemaps.arcgis.com`, `www.arcgis.com`, `cdn.arcgis.com`), quindi in produzione serve un proxy
sullo stesso server dell'applicazione Flex, per esempio il
[resource-proxy di Esri](https://github.com/Esri/resource-proxy). Il proxy deve:

- ammettere almeno `basemaps.arcgis.com`, `www.arcgis.com` e `cdn.arcgis.com`
  (oltre agli host di eventuali stili non Esri);
- restituire i dati binari senza alterarli (le tile possono arrivare compresse gzip: il layer le decomprime).

La policy deve arrivare direttamente dall'URL richiesto: Flash ignora un `crossdomain.xml`
ottenuto tramite redirect verso un altro schema o host, anche se il contenuto è corretto.
In quel caso il layer riceve `#2048 Security sandbox violation` e va usato il proxy.
Le tile delle basemap raster non hanno questo vincolo perché sono immagini: Flash le mostra
anche senza policy, mentre i dati (stile, metadati, tile PBF, glyph, sprite) vanno letti.

## Copertura dello stile

| Elemento | Stato |
|---|---|
| `background`, `fill`, `line`, `circle` | Supportati: colori, opacità, `fill-pattern`, `line-dasharray`, cap/join, `*-translate` |
| `symbol` | Etichette (glyph SDF con alone), testo lungo le linee, a capo, ancoraggi, offset, `text-transform`, icone da sprite, rotazioni, collisioni con priorità per ordine di stile |
| Filtri | Sintassi legacy ed espressioni |
| Funzioni | `stops` legacy (zoom, proprietà, zoom+proprietà) ed espressioni (`match`, `case`, `interpolate`, `step`, `coalesce`, `let`/`var`, matematica, stringhe, colori…) |
| `fill-extrusion` | Disegnata piatta (impronta) |
| `line-gap-width` | Approssimata con una linea singola |
| `raster`, `hillshade`, `heatmap`, terreno, cielo | Ignorati |
| `icon-text-fit`, `text-variable-anchor`, `symbol-sort-key` | Non implementati |
| Scritture complesse (arabo, indiane, bidi) | Non supportate (latino, greco, cirillico, CJK sì) |

## Limiti noti e cose non verificate

- **Proiezione**: provato solo Web Mercator (102100/3857). Il codice per i servizi Esri con
  altra proiezione (livelli presi dal `tileInfo` del servizio) non è stato provato.
- **`wrapAround180`** non è supportato (niente ripetizione del mondo oltre l'antimeridiano).
- **Rotazione della mappa** (`mapRotation`) non provata.
- Le etichette vengono ricalcolate a fine pan/zoom, non durante il movimento.
- Rendering su CPU: 20–100 ms per tile, distribuiti su più frame.
- Esri **Basemap Styles service v2** (`basemapstyles-api.arcgis.com`, con API key) non provato;
  provati il VectorTileServer `World_Basemap_v2` e gli item pubblici Esri (Street, Navigation,
  Street Night, Light/Dark Gray Canvas con i relativi layer di riferimento).
- Le basemap "Canvas" di Esri hanno le etichette in un item separato ("Reference"): si aggiunge
  come secondo `VectorTileLayer` sopra la base (vedi l'esempio).

## Struttura

```
src/org/falpi/ags/layers/
  VectorTileLayer.as             il componente (integrazione con Map, tile, frame, etichette)
src/org/falpi/ags/layers/vectorTiles/
  source/                        risoluzione di servizio / item / stile / TileJSON
  style/                         stile Mapbox GL: layer, proprietà, filtri, espressioni, colori
  mvt/, pbf/                     decoder Protocol Buffers e Mapbox Vector Tile
  render/                        renderer CPU delle tile e sprite
  labels/                        glyph SDF, impaginazione testo, collisioni, posizionamento
  net/, util/                    caricamento con proxy/token/gzip, URL
examples/                        applicazione di esempio
src/manifest.xml                 namespace MXML http://falpi.org/ags
libs/agslib-3.7-2014-11-06.swc   ArcGIS API for Flex (linkata esternamente)
```

## Build

**Flash Builder 4.7**: *File > Import > General > Existing Projects into Workspace* e scegliere
questa cartella. È un progetto libreria Flex (SDK 4.6) che produce `bin/arcgis-flex-vectortiles.swc`;
framework Flex e `libs/agslib-3.7-2014-11-06.swc` sono linkati esternamente.
Lo SWC dell'ArcGIS API for Flex non è nel repository: va copiato in `libs/` (vedi [libs/README.md](libs/README.md)).
Lo SWC compilato di questa estensione è disponibile nelle Release del repository.

L'esempio `examples/VectorTileDemo.mxml` si compila in un progetto applicazione Flex che linka
lo SWC (o i sorgenti di `src/`) e lo SWC ArcGIS; la pagina proxy si passa con il FlashVar `proxyURL`.
