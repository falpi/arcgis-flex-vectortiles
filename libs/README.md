# libs

The project compiles against the **ArcGIS API for Flex 3.7**, which is not included in the repository
(it is an Esri library, retired in 2016 and no longer downloadable from Esri's website).

Copy the file

    agslib-3.7-2014-11-06.swc

here before compiling. The library is linked externally: `arcgis-flex-vectortiles.swc` does not
contain any Esri code, and the application that uses it must link the API SWC itself.
