# TreeHunter - a script to replicate Polish Monumental Tree Registry to OSM 

## Tags

The following OSM page lists the supported tags https://wiki.openstreetmap.org/wiki/Tag:natural=tree
Currently the script uses only a subset of those, namely:

- Age
- Height
- Species:PL
- Procted -> yes/no
- Name
- Source -> RPDP

    Sample tree added by the script: https://master.apis.dev.openstreetmap.org/node/4319597672 (DEV OSM server)

- Website -> RPDP link

## APIs used

OSM APIs:

- changeset
- node create

See https://wiki.openstreetmap.org/wiki/API\_v0.6#Create:\_PUT\_.2Fapi.2F0.6.2F.5Bnode.7Cway.7Crelation.5D.2Fcreate 
for more info

Additionally Overpass search API is used to check for duplicates.

## Running

Set OSM\_USER and OSM\_PASSWD environment variables for authentication the calls to OSM

## Bugs and Help

Bugs can be reported via GitHub https://github.com/rdktz/treehunter/issues

Author contact <az.zdzi@yahoo.com>

Readme generated with https://metacpan.org/pod/distribution/Pod-Markdown/bin/pod2markdown 
