# libs

Il progetto compila contro l'**ArcGIS API for Flex 3.7**, che non è inclusa nel repository
(è una libreria Esri, ritirata nel 2016 e non più scaricabile dal sito Esri).

Copiare qui il file

    agslib-3.7-2014-11-06.swc

prima di compilare. La libreria è linkata esternamente: `arcgis-flex-vectortiles.swc` non
contiene codice Esri, e l'applicazione che lo usa deve linkare a sua volta lo SWC dell'API.
