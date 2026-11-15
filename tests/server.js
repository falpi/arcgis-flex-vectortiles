#!/usr/bin/env node
/*
 * Development server for the examples: it hosts a SWF and a proxy page on the same origin, then opens the SWF in
 * the standalone Flash Player.
 *
 *   node server.js [<file.swf>] [--flashbuilder <folder>] [--player <FlashPlayer.exe>] [--no-player] [--keep]
 *                  [--allow host,host] [--verbose]
 *
 *   http://localhost:8790/<file.swf>   the SWF (and the other files of its folder)
 *   http://localhost:8790/             a page that embeds it, for a browser that still has Flash
 *   http://localhost:8790/proxy?<url>  proxy page (ArcGIS convention): <url> is requested and its answer returned
 *
 * Without a SWF, the demo of the repository (examples/src/HybridTileDemo.mxml) is built first, from the sources of
 * the library, into the output folder of its Flash Builder project (examples/bin-debug/HybridTileDemo.swf).
 *
 * The tools come from Flash Builder: --flashbuilder (its installation folder, the "eclipse home"), otherwise the
 * default installation folders of Flash Builder 4.7 and 4.6. From it: the Flex SDK 4.6 and the Java of Flash
 * Builder to build, the debugger player (player\win\<version>\FlashPlayerDebugger.exe) to run. --player gives
 * another Flash Player; --no-player only serves (open the SWF URL yourself).
 *
 * Being on the same origin as the SWF, the proxy needs no crossdomain.xml. It answers only on 127.0.0.1, and only
 * for the hosts of ALLOWED_SITES (and --allow): an open proxy on a known port could be used by any page of the
 * browser to reach other addresses. It is meant for development, not as a proxy for production.
 *
 * When the player is closed the server stops, unless --keep is given.
 */
'use strict';

const http = require('http');
const https = require('https');
const fs = require('fs');
const path = require('path');
const zlib = require('zlib');
const childProcess = require('child_process');

const PORT = 8790;
const HOST = '127.0.0.1';

/** Sites the proxy may reach: the host itself or any of its sub-domains. */
const ALLOWED_SITES = ['arcgis.com', 'arcgisonline.com', 'openstreetmap.org'];

const MAX_REDIRECTS = 5;

/** The repository, and the demo built when no SWF is given. */
const REPOSITORY = path.resolve(__dirname, '..');
const DEMO_SOURCE = path.join(REPOSITORY, 'examples', 'src', 'HybridTileDemo.mxml');
const DEMO_OUTPUT = path.join(REPOSITORY, 'examples', 'bin-debug', 'HybridTileDemo.swf');

/** Where the Windows setups of Flash Builder install it, the newest first. */
const FLASH_BUILDER_FOLDERS = [
    ['ProgramFiles', 'Adobe\\Adobe Flash Builder 4.7 (64 Bit)'],
    ['ProgramFiles(x86)', 'Adobe\\Adobe Flash Builder 4.7'],
    ['ProgramFiles', 'Adobe\\Adobe Flash Builder 4.7'],
    ['ProgramFiles(x86)', 'Adobe\\Adobe Flash Builder 4.6'],
    ['ProgramFiles', 'Adobe\\Adobe Flash Builder 4.6']
];

const TYPES = {
    '.swf': 'application/x-shockwave-flash',
    '.html': 'text/html; charset=utf-8',
    '.js': 'text/javascript',
    '.css': 'text/css',
    '.xml': 'text/xml',
    '.json': 'application/json',
    '.png': 'image/png',
    '.jpg': 'image/jpeg',
    '.gif': 'image/gif',
    '.swz': 'application/octet-stream'
};

// ----------------------------------------------------------------------------------------------------------------
// arguments
// ----------------------------------------------------------------------------------------------------------------

/** An argument as Windows may pass it: quotes and a trailing separator left by "C:\dir\" are dropped. */
function cleanPath(value) {
    return value == null ? null : value.replace(/^"+|"+$/g, '').replace(/[\\/]+$/, '');
}

function parseArguments(argv) {
    const options = {swf: null, flashBuilder: null, player: null, noPlayer: false, keep: false, allow: [], verbose: false};
    for (let i = 0; i < argv.length; i++) {
        const arg = argv[i];
        if (arg === '--flashbuilder') {
            options.flashBuilder = cleanPath(argv[++i]);
        } else if (arg === '--player') {
            const value = cleanPath(argv[++i]);
            // a folder: the one of Flash Builder (as given by earlier versions of the launch configuration)
            if (/\.exe$/i.test(value)) {
                options.player = value;
            } else {
                options.flashBuilder = value;
            }
        } else if (arg === '--no-player') {
            options.noPlayer = true;
        } else if (arg === '--verbose') {
            options.verbose = true;
        } else if (arg === '--keep') {
            options.keep = true;
        } else if (arg === '--allow') {
            options.allow = String(argv[++i] || '').split(',').map(s => s.trim().toLowerCase()).filter(Boolean);
        } else if (/^--/.test(arg)) {
            fail('Unknown option: ' + arg + '\n' + USAGE);
        } else if (options.swf == null) {
            options.swf = path.resolve(cleanPath(arg));
        } else {
            fail('Unexpected argument: ' + arg + '\n' + USAGE);
        }
    }
    return options;
}

const USAGE = 'Usage: server [<file.swf>] [--flashbuilder <folder>] [--player <FlashPlayer.exe>] [--no-player] ' +
    '[--keep] [--allow host,host] [--verbose]';

function fail(message) {
    console.error(message);
    process.exit(1);
}

// ----------------------------------------------------------------------------------------------------------------
// Flash Builder: the SDK, its Java and the standalone Flash Player
// ----------------------------------------------------------------------------------------------------------------

/**
 * The installation folder of Flash Builder: the one given (or the folder above it, if the one given is its
 * eclipse folder), otherwise the first default folder that exists. Null when none is found.
 */
function findFlashBuilder(given) {
    if (given) {
        for (const folder of [given, path.dirname(given)]) {
            if (isFlashBuilder(folder)) {
                return folder;
            }
        }
        fail('Not a Flash Builder installation (no sdks or player folder): ' + given);
    }
    for (const [variable, folder] of FLASH_BUILDER_FOLDERS) {
        const base = process.env[variable];
        if (base && isFlashBuilder(path.join(base, folder))) {
            return path.join(base, folder);
        }
    }
    return null;
}

function isFlashBuilder(folder) {
    return fs.existsSync(path.join(folder, 'sdks')) || fs.existsSync(path.join(folder, 'player'));
}

function missingFlashBuilder(what) {
    return 'Flash Builder not found, needed for ' + what + '. Give its installation folder with --flashbuilder ' +
        '(searched: ' + FLASH_BUILDER_FOLDERS.map(([variable, folder]) => '%' + variable + '%\\' + folder).join(', ') + ').';
}

/** The Flex SDK 4.6 of Flash Builder (or its newest 4.x SDK). */
function findSdk(flashBuilder) {
    const root = path.join(flashBuilder, 'sdks');
    let names = [];
    try {
        names = fs.readdirSync(root);
    } catch (error) {
        return null;
    }
    const sdks = names.filter(name => /^4\./.test(name) && fs.existsSync(path.join(root, name, 'lib', 'mxmlc.jar')))
        .sort(compareVersions).reverse();
    const preferred = sdks.indexOf('4.6.0') >= 0 ? '4.6.0' : sdks[0];
    return preferred ? path.join(root, preferred) : null;
}

/** The Java of Flash Builder, then JAVA_HOME, then the one on the PATH. */
function findJava(flashBuilder) {
    for (const java of [path.join(flashBuilder, 'jre', 'bin', 'java.exe'),
        process.env.JAVA_HOME ? path.join(process.env.JAVA_HOME, 'bin', 'java.exe') : null]) {
        if (java && fs.existsSync(java)) {
            return java;
        }
    }
    return 'java';
}

/** The newest debugger player of Flash Builder (player\win\<version>\FlashPlayerDebugger.exe). */
function findPlayer(flashBuilder) {
    const root = path.join(flashBuilder, 'player', 'win');
    let versions = [];
    try {
        versions = fs.readdirSync(root);
    } catch (error) {
        return null;
    }
    const players = versions.filter(version => fs.existsSync(path.join(root, version, 'FlashPlayerDebugger.exe')))
        .sort(compareVersions).reverse();
    return players.length > 0 ? path.join(root, players[0], 'FlashPlayerDebugger.exe') : null;
}

function compareVersions(a, b) {
    const x = a.split('.').map(Number);
    const y = b.split('.').map(Number);
    for (let i = 0; i < Math.max(x.length, y.length); i++) {
        const d = (x[i] || 0) - (y[i] || 0);
        if (d !== 0) {
            return d;
        }
    }
    return 0;
}

// ----------------------------------------------------------------------------------------------------------------
// build of the demo
// ----------------------------------------------------------------------------------------------------------------

/** Builds the demo from the sources of the library into DEMO_OUTPUT, with the framework merged into the SWF. */
function buildDemo(flashBuilder) {
    if (flashBuilder == null) {
        fail(missingFlashBuilder('building the demo'));
    }
    const sdk = findSdk(flashBuilder);
    if (sdk == null) {
        fail('No Flex SDK 4.x with mxmlc in ' + path.join(flashBuilder, 'sdks'));
    }
    const libs = path.join(REPOSITORY, 'libs');
    const agslib = (fs.existsSync(libs) ? fs.readdirSync(libs) : []).filter(name => /^agslib.*\.swc$/i.test(name))[0];
    if (!agslib) {
        fail('The ArcGIS API for Flex SWC is not in ' + libs + ' (see libs/README.md).');
    }
    const java = findJava(flashBuilder);
    console.log('Building ' + DEMO_SOURCE);
    console.log('  SDK  ' + sdk);
    console.log('  Java ' + java);
    fs.mkdirSync(path.dirname(DEMO_OUTPUT), {recursive: true});
    const result = childProcess.spawnSync(java, [
        '-Xmx1024m', '-Dsun.io.useCanonCaches=false', '-jar', path.join(sdk, 'lib', 'mxmlc.jar'),
        '+flexlib=' + path.join(sdk, 'frameworks'),
        '-source-path+=' + path.join(REPOSITORY, 'src'),
        '-compiler.namespaces.namespace+=http://falpi.org/ags,' + path.join(REPOSITORY, 'src', 'manifest.xml'),
        '-library-path+=' + path.join(libs, agslib),
        '-static-link-runtime-shared-libraries=true',
        '-locale', 'en_US',
        '-output', DEMO_OUTPUT,
        DEMO_SOURCE
    ], {stdio: 'inherit'});
    if (result.error) {
        fail('Cannot start Java (' + java + '): ' + result.error.message);
    }
    if (result.status !== 0 || !fs.existsSync(DEMO_OUTPUT)) {
        fail('The build of the demo failed.');
    }
    return DEMO_OUTPUT;
}

// ----------------------------------------------------------------------------------------------------------------
// proxy page
// ----------------------------------------------------------------------------------------------------------------

function allowedHost(hostname, extra) {
    const host = String(hostname).toLowerCase();
    return ALLOWED_SITES.concat(extra).some(site => host === site || host.endsWith('.' + site));
}

/** Requests the target (following redirects within the allowed sites) and returns its answer, decompressed. */
function forward(request, response, target, extra, redirects, started) {
    let url;
    try {
        url = new URL(target);
    } catch (error) {
        return answer(response, 400, 'Not a URL: ' + target, target, started);
    }
    if (url.protocol !== 'http:' && url.protocol !== 'https:') {
        return answer(response, 400, 'Only http and https URLs', target, started);
    }
    if (!allowedHost(url.hostname, extra)) {
        return answer(response, 403, 'Host not allowed by the development proxy: ' + url.hostname +
            ' (see ALLOWED_SITES in tests/server.js, or --allow)', target, started);
    }
    const client = url.protocol === 'https:' ? https : http;
    const headers = {'user-agent': 'arcgis-flex-vectortiles dev proxy', 'accept': '*/*', 'accept-encoding': 'gzip, deflate, br'};
    if (request.headers['content-type']) {
        headers['content-type'] = request.headers['content-type'];
    }
    const outgoing = client.request(url, {method: request.method === 'POST' ? 'POST' : 'GET', headers}, incoming => {
        const status = incoming.statusCode;
        if (status >= 300 && status < 400 && incoming.headers.location && redirects < MAX_REDIRECTS) {
            incoming.resume();
            const next = new URL(incoming.headers.location, url).toString();
            return forward(request, response, next, extra, redirects + 1, started);
        }
        // decompressed here: the layer reads JSON styles as text, which it does not inflate
        let body = incoming;
        const encoding = String(incoming.headers['content-encoding'] || '').toLowerCase();
        if (encoding === 'gzip') {
            body = incoming.pipe(zlib.createGunzip());
        } else if (encoding === 'deflate') {
            body = incoming.pipe(zlib.createInflate());
        } else if (encoding === 'br') {
            body = incoming.pipe(zlib.createBrotliDecompress());
        }
        const chunks = [];
        body.on('data', chunk => chunks.push(chunk));
        body.on('error', error => answer(response, 502, 'Cannot read the answer: ' + error.message, target, started));
        body.on('end', () => {
            const data = Buffer.concat(chunks);
            const out = {'content-length': data.length, 'cache-control': 'no-store'};
            if (incoming.headers['content-type']) {
                out['content-type'] = incoming.headers['content-type'];
            }
            response.writeHead(status, out);
            response.end(data);
            log(status, data.length, started, target);
        });
    });
    outgoing.setTimeout(30000, () => outgoing.destroy(new Error('timeout')));
    outgoing.on('error', error => answer(response, 502, 'Cannot reach the server: ' + error.message, target, started));
    request.pipe(outgoing);
}

function answer(response, status, message, target, started) {
    if (!response.headersSent) {
        response.writeHead(status, {'content-type': 'text/plain; charset=utf-8'});
        response.end(message);
    }
    log(status, message.length, started, target + ' (' + message + ')');
}

function log(status, bytes, started, what) {
    const ms = Date.now() - started;
    console.log(String(status).padEnd(4) + String(bytes).padStart(9) + ' B ' + String(ms).padStart(6) + ' ms  ' + what);
}

// ----------------------------------------------------------------------------------------------------------------
// files of the SWF
// ----------------------------------------------------------------------------------------------------------------

function page(swfName) {
    return '<!DOCTYPE html>\n<html><head><meta charset="utf-8"><title>' + swfName + '</title>' +
        '<style>html,body{margin:0;height:100%;overflow:hidden}</style></head><body>' +
        '<object type="application/x-shockwave-flash" data="' + swfName + '" width="100%" height="100%">' +
        '<param name="allowScriptAccess" value="sameDomain"><param name="movie" value="' + swfName + '">' +
        '<p>This browser has no Flash Player: open http://localhost:' + PORT + '/' + swfName +
        ' with the standalone Flash Player.</p></object></body></html>';
}

function serveFile(request, response, folder, swfName) {
    const name = decodeURIComponent(new URL(request.url, 'http://localhost').pathname).replace(/^\/+/, '');
    if (name === '') {
        response.writeHead(200, {'content-type': TYPES['.html'], 'cache-control': 'no-store'});
        return response.end(page(swfName));
    }
    const file = path.resolve(folder, name);
    if (!file.startsWith(folder + path.sep)) {
        response.writeHead(403);
        return response.end();
    }
    fs.readFile(file, (error, data) => {
        if (error) {
            response.writeHead(404, {'content-type': 'text/plain'});
            return response.end('Not found');
        }
        response.writeHead(200, {
            'content-type': TYPES[path.extname(file).toLowerCase()] || 'application/octet-stream',
            'content-length': data.length,
            'cache-control': 'no-store'
        });
        response.end(data);
    });
}

// ----------------------------------------------------------------------------------------------------------------
// main
// ----------------------------------------------------------------------------------------------------------------

function main() {
    const options = parseArguments(process.argv.slice(2));
    const flashBuilder = findFlashBuilder(options.flashBuilder);
    if (options.swf == null) {
        options.swf = buildDemo(flashBuilder);
    } else if (!fs.existsSync(options.swf)) {
        fail('SWF not found: ' + options.swf + ' (build it first, or give no SWF to build the demo)');
    }
    let player = null;
    if (!options.noPlayer) {
        if (options.player != null) {
            if (!fs.existsSync(options.player)) {
                fail('Flash Player not found: ' + options.player);
            }
            player = options.player;
        } else if (flashBuilder == null) {
            fail(missingFlashBuilder('the standalone Flash Player') + ' Or give it with --player, or use --no-player.');
        } else {
            player = findPlayer(flashBuilder);
            if (player == null) {
                fail('No standalone Flash Player in ' + path.join(flashBuilder, 'player', 'win') +
                    ': give one with --player, or use --no-player.');
            }
        }
    }
    const folder = path.dirname(options.swf);
    const swfName = path.basename(options.swf);

    const server = http.createServer((request, response) => {
        const started = Date.now();
        if (options.verbose) {
            console.log('>> ' + request.method + ' ' + request.url + ' ' + JSON.stringify(request.headers));
        }
        const pathname = new URL(request.url, 'http://localhost').pathname;
        if (pathname === '/proxy') {
            const query = request.url.indexOf('?');
            const target = query >= 0 ? decodeTarget(request.url.substring(query + 1)) : '';
            return forward(request, response, target, options.allow, 0, started);
        }
        serveFile(request, response, folder, swfName);
    });
    server.on('error', error => {
        if (error.code === 'EADDRINUSE') {
            fail('Port ' + PORT + ' is in use: is another instance of this server running?');
        }
        fail(error.message);
    });
    server.listen(PORT, HOST, () => {
        const swfURL = 'http://localhost:' + PORT + '/' + encodeURIComponent(swfName);
        console.log('Serving ' + options.swf);
        console.log('  SWF        ' + swfURL);
        console.log('  proxy page http://localhost:' + PORT + '/proxy');
        console.log('  sites      ' + ALLOWED_SITES.concat(options.allow).join(', '));
        if (player == null) {
            console.log('No player (--no-player): open the SWF URL yourself. Ctrl+C to stop.');
            return;
        }
        console.log('  player     ' + player);
        const child = childProcess.spawn(player, [swfURL], {stdio: 'ignore'});
        child.on('error', error => console.error('Cannot start the Flash Player: ' + error.message));
        child.on('exit', () => {
            if (options.keep) {
                console.log('Flash Player closed; the server keeps running (Ctrl+C to stop).');
                return;
            }
            console.log('Flash Player closed: server stopped.');
            process.exit(0);
        });
        process.on('exit', () => {
            try {
                child.kill();
            } catch (error) {
                // already closed
            }
        });
    });

    watchParent();
}

/**
 * Stops when the process that started the server ends: the Terminate button of Flash Builder (or of another
 * tool) ends server.cmd, not node, which would otherwise keep the port busy and the player open.
 */
function watchParent() {
    const parent = process.ppid;
    if (!(parent > 1)) {
        return;
    }
    setInterval(() => {
        try {
            process.kill(parent, 0);
        } catch (error) {
            console.log('Started by a process that has ended: server stopped.');
            process.exit(0);
        }
    }, 1000).unref();
}

/** The target as the layers send it (proxy?https://...); an encoded one (proxy?https%3A%2F%2F...) is decoded. */
function decodeTarget(value) {
    return /^https?%3A/i.test(value) ? decodeURIComponent(value) : value;
}

main();
