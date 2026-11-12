package org.falpi.ags.layers.vectorTiles.gpu
{
    import org.falpi.ags.layers.vectorTiles.mvt.MvtFeature;
    import org.falpi.ags.layers.vectorTiles.mvt.VectorTile;
    import org.falpi.ags.layers.vectorTiles.render.LayerBucket;
    import org.falpi.ags.layers.vectorTiles.render.SourceTile;
    import org.falpi.ags.layers.vectorTiles.render.SpriteAtlas;
    import org.falpi.ags.layers.vectorTiles.style.StyleColor;

    import flash.display.BitmapData;
    import flash.display.CapsStyle;
    import flash.display.JointStyle;
    import flash.display.Stage;
    import flash.display.Stage3D;
    import flash.display3D.Context3D;
    import flash.display3D.Context3DBlendFactor;
    import flash.display3D.Context3DProgramType;
    import flash.display3D.Context3DVertexBufferFormat;
    import flash.display3D.IndexBuffer3D;
    import flash.display3D.Program3D;
    import flash.display3D.VertexBuffer3D;
    import flash.events.ErrorEvent;
    import flash.events.Event;
    import flash.geom.Rectangle;
    import flash.utils.ByteArray;
    import flash.utils.Dictionary;
    import flash.utils.Endian;

    /**
     * Draws prepared buckets with Stage3D, under the whole display list. One instance per layer;
     * the first Stage3D of the stage is used by one renderer at a time.
     *
     * All the fill buckets of a data tile at a zoom go into one mesh (style order kept by the index
     * order), so a display tile costs one draw call per source. Meshes keep the geometry in tile extent
     * units; each draw maps them to clip space with one constant register (scale, offset), so the same
     * mesh serves every display tile drawn from the data tile (overzoom) and every frame.
     */
    public final class GpuRenderer
    {
        private static const MAX_VERTICES:int = 65535;
        private static const MESH_TTL_FRAMES:int = 900;
        private static var s_owners:Dictionary = new Dictionary(true);
        /** Called (once) when a renderer releases its Stage3D: layers waiting to use it. */
        private static var s_waiting:Array = [];

        private static const FILL_VERTEX:String =
            "mov vt0, vc1\n" +                  // (0, 0, 0, 1)
            "mul vt0.xy, va0.xy, vc0.xy\n" +    // tile units -> clip space
            "add vt0.xy, vt0.xy, vc0.zw\n" +
            "mov op, vt0\n" +
            "mov v0, va1\n";                    // color
        private static const FILL_FRAGMENT:String =
            "mul ft0, v0, fc0\n" +              // fc0: color multiplier
            "mov oc, ft0\n";

        /**
         * Lines: va0 position (tile units), va1 extrusion direction (miter scaled, side included),
         * va2 (half width px with the sign of the side, distance along the line in tile units,
         * dash period px, dash "on" fraction), va3 color.
         * vc0 tile units -> clip, vc1 (0,0,0,1), vc2 (tile px -> clip x, tile px -> clip y,
         * tile units -> tile px, 0.5 = antialiasing margin px).
         * Antialiasing does not rely on multisampling: the strip is half a pixel wider on each side and the
         * fragment alpha is the coverage computed from the distance to the center line (v2).
         */
        private static const LINE_VERTEX:String =
            "mov vt0, vc1\n" +
            "mul vt0.xy, va0.xy, vc0.xy\n" +    // center line -> clip space
            "add vt0.xy, vt0.xy, vc0.zw\n" +
            "mov vt3, vc1\n" +
            "abs vt3.x, va2.x\n" +             // half width
            "add vt3.y, vt3.x, vc2.w\n" +      // + antialiasing margin
            "mul vt1.xy, va1.xy, vt3.yy\n" +    // extrusion in tile pixels
            "mul vt1.xy, vt1.xy, vc2.xy\n" +    // -> clip space (constant width on screen)
            "add vt0.xy, vt0.xy, vt1.xy\n" +
            "mov op, vt0\n" +
            "mov v0, va3\n" +
            "mov vt2, vc1\n" +
            "mul vt2.x, va2.y, vc2.z\n" +      // distance in tile pixels
            "div vt2.x, vt2.x, va2.z\n" +      // in dash periods
            "mov vt2.y, va2.w\n" +             // "on" fraction
            "mov v1, vt2\n" +
            "div vt3.z, va2.x, vt3.x\n" +      // side: +1 / -1
            "mul vt3.z, vt3.z, vt3.y\n" +      // signed distance from the center at this vertex
            "mov vt4, vc1\n" +
            "mov vt4.x, vt3.z\n" +
            "mov vt4.y, vt3.y\n" +
            "mov v2, vt4\n";
        private static const LINE_FRAGMENT:String =
            "frc ft0.x, v1.x\n" +              // position inside the dash period
            "sub ft0.y, v1.y, ft0.x\n" +       // negative in the gap
            "kil ft0.y\n" +
            "abs ft1.x, v2.x\n" +              // distance from the center line
            "sub ft1.x, v2.y, ft1.x\n" +       // coverage: 0.5 at the true edge
            "sat ft1.x, ft1.x\n" +
            "mul ft2, v0, fc0\n" +
            "mul ft2.w, ft2.w, ft1.x\n" +
            "mov oc, ft2\n";
        /** Dash period of solid lines: never reaches the gap. */
        private static const SOLID_PERIOD:Number = 1e9;

        /** Registers a function called when a Stage3D is released by another renderer. */
        public static function waitForStage3D(callback:Function):void
        {
            if (s_waiting.indexOf(callback) < 0)
            {
                s_waiting.push(callback);
            }
        }

        public static function stopWaiting(callback:Function):void
        {
            var i:int = s_waiting.indexOf(callback);
            if (i >= 0)
            {
                s_waiting.splice(i, 1);
            }
        }

        private var m_stage:Stage;
        private var m_stage3D:Stage3D;
        private var m_context:Context3D;
        private var m_fillProgram:Program3D;
        private var m_lineProgram:Program3D;
        private var m_veilVertices:VertexBuffer3D;
        private var m_veilIndices:IndexBuffer3D;
        private var m_generation:int = 0;
        private var m_onState:Function;

        private var m_bufferWidth:int;
        private var m_bufferHeight:int;
        private var m_view:Rectangle = new Rectangle();
        private var m_frame:int = 0;
        private var m_alpha:Number = 1;

        /** VectorTile -> {zoom key -> mesh}. */
        private var m_meshes:Dictionary = new Dictionary();
        /** sprite name -> {rgb, a}: average color of fill patterns (patterns are not textured yet). */
        private var m_patternColors:Object = {};

        /** True once a hardware context is ready. */
        public var available:Boolean = false;
        /** Set when the GPU cannot be used (no Stage3D, software only, error): the layer falls back to CPU. */
        public var failure:String;
        /** The failure is only that another layer is using the Stage3D (it may be released later). */
        public var busy:Boolean = false;
        /** Stage3D driver description (Context3D.driverInfo). */
        public var driverInfo:String;
        /** Sprites of the style (fill-pattern colors). */
        public var sprites:SpriteAtlas;
        /** Diagnostics: when set, the next frame is copied here (back buffer size) and the field is cleared. */
        public var captureTarget:BitmapData;

        /** @param onState called with no arguments when available or failure change. */
        public function GpuRenderer(stage:Stage, onState:Function)
        {
            m_stage = stage;
            m_onState = onState;
        }

        public function start():void
        {
            if (m_stage.stage3Ds == null || m_stage.stage3Ds.length == 0)
            {
                fail("Stage3D not available");
                return;
            }
            var stage3D:Stage3D = m_stage.stage3Ds[0];
            if (s_owners[stage3D] != null && s_owners[stage3D] != this)
            {
                busy = true;
                fail("Stage3D used by another layer");
                return;
            }
            s_owners[stage3D] = this;
            m_stage3D = stage3D;
            m_stage3D.addEventListener(Event.CONTEXT3D_CREATE, contextCreated);
            m_stage3D.addEventListener(ErrorEvent.ERROR, contextError);
            try
            {
                m_stage3D.requestContext3D();
            }
            catch (error:Error)
            {
                fail("requestContext3D: " + error.message);
            }
        }

        public function dispose():void
        {
            disposeMeshes();
            var released:Boolean = false;
            if (m_stage3D != null)
            {
                m_stage3D.visible = false;
                m_stage3D.removeEventListener(Event.CONTEXT3D_CREATE, contextCreated);
                m_stage3D.removeEventListener(ErrorEvent.ERROR, contextError);
                if (s_owners[m_stage3D] == this)
                {
                    delete s_owners[m_stage3D];
                    released = true;
                }
            }
            if (m_context != null)
            {
                m_context.dispose();
            }
            m_context = null;
            m_stage3D = null;
            available = false;
            if (released)
            {
                var waiting:Array = s_waiting;
                s_waiting = [];
                for each (var callback:Function in waiting)
                {
                    callback();
                }
            }
        }

        private function fail(message:String):void
        {
            failure = message;
            available = false;
            if (m_onState != null)
            {
                m_onState();
            }
        }

        private function contextError(event:ErrorEvent):void
        {
            fail("Context3D: " + event.text);
        }

        private function contextCreated(event:Event):void
        {
            // also called after a context loss: every GPU resource must be created again
            m_context = m_stage3D.context3D;
            driverInfo = m_context.driverInfo;
            if (driverInfo.toLowerCase().indexOf("software") >= 0)
            {
                // software emulation is slower than the CPU renderer
                fail("software Stage3D (" + driverInfo + ")");
                return;
            }
            m_generation++;
            m_meshes = new Dictionary();
            m_bufferWidth = 0;
            m_bufferHeight = 0;
            try
            {
                m_context.enableErrorChecking = false;
                m_fillProgram = m_context.createProgram();
                m_fillProgram.upload(Agal.assemble(false, FILL_VERTEX), Agal.assemble(true, FILL_FRAGMENT));
                m_lineProgram = m_context.createProgram();
                m_lineProgram.upload(Agal.assemble(false, LINE_VERTEX), Agal.assemble(true, LINE_FRAGMENT));
                m_context.setBlendFactors(Context3DBlendFactor.SOURCE_ALPHA, Context3DBlendFactor.ONE_MINUS_SOURCE_ALPHA);
                createVeil();
            }
            catch (error:Error)
            {
                fail("setup: " + error.message);
                return;
            }
            var wasAvailable:Boolean = available;
            available = true;
            if (!wasAvailable && m_onState != null)
            {
                m_onState();
            }
        }

        /** Full screen white quad (clip space) used to fade the frame for the layer opacity. */
        private function createVeil():void
        {
            var data:ByteArray = newVertexBytes();
            for each (var corner:Array in [[-1, -1], [1, -1], [1, 1], [-1, 1]])
            {
                data.writeFloat(corner[0]);
                data.writeFloat(corner[1]);
                data.writeUnsignedInt(0xFFFFFFFF);
            }
            m_veilVertices = m_context.createVertexBuffer(4, 3);
            m_veilVertices.uploadFromByteArray(data, 0, 0, 4);
            m_veilIndices = m_context.createIndexBuffer(6);
            m_veilIndices.uploadFromVector(Vector.<uint>([0, 1, 2, 0, 2, 3]), 0, 6);
        }

        // ------------------------------------------------------------------
        // frame
        // ------------------------------------------------------------------

        /** Hides the Stage3D layer (the map is not on screen). */
        public function hide():void
        {
            if (m_stage3D != null)
            {
                m_stage3D.visible = false;
            }
        }

        /**
         * Starts a frame over the given stage rectangle (the map), cleared with the background color.
         * @param alpha effective opacity of the layer: applied at the end by fading towards white, like the
         *        CPU tiles over the (white) map container
         * Returns false when nothing can be drawn.
         */
        public function beginFrame(view:Rectangle, background:StyleColor, alpha:Number):Boolean
        {
            if (!available || m_context == null || m_context.driverInfo == "Disposed")
            {
                return false;
            }
            var width:int = Math.round(view.width);
            var height:int = Math.round(view.height);
            if (width < 32 || height < 32)
            {
                hide();
                return false;
            }
            m_frame++;
            m_alpha = Math.max(0, Math.min(1, alpha));
            m_view.x = Math.round(view.x);
            m_view.y = Math.round(view.y);
            m_view.width = width;
            m_view.height = height;
            m_stage3D.x = m_view.x;
            m_stage3D.y = m_view.y;
            m_stage3D.visible = true;
            if (width != m_bufferWidth || height != m_bufferHeight)
            {
                m_context.configureBackBuffer(width, height, 4, false);
                m_bufferWidth = width;
                m_bufferHeight = height;
            }
            if (background != null)
            {
                m_context.clear(((background.rgb >> 16) & 255) / 255, ((background.rgb >> 8) & 255) / 255,
                                (background.rgb & 255) / 255, 1);
            }
            else
            {
                m_context.clear(1, 1, 1, 1);
            }
            m_context.setProgramConstantsFromVector(Context3DProgramType.VERTEX, 1, Vector.<Number>([0, 0, 0, 1]));
            m_context.setProgramConstantsFromVector(Context3DProgramType.FRAGMENT, 0, Vector.<Number>([1, 1, 1, 1]));
            m_lineMode = -1;
            return true;
        }

        /**
         * Builds (if needed) the meshes of a display tile, so that drawing it later costs no CPU time.
         * @param fills {bucket, source} of the tile in drawing order (TileRenderer gpuFills)
         */
        public function prepareTile(fills:Array, zoom:Number):void
        {
            if (!available || m_context == null)
            {
                return;
            }
            var list:Array = groups(fills);
            for (var i:int = 0; i < list.length; i++)
            {
                meshFor(list[i], zoom, i);
            }
        }

        /** -1 unknown, 0 fill program bound, 1 line program bound. */
        private var m_lineMode:int = -1;

        private function useProgram(line:Boolean):void
        {
            var mode:int = line ? 1 : 0;
            if (mode == m_lineMode)
            {
                return;
            }
            m_lineMode = mode;
            if (line)
            {
                m_context.setProgram(m_lineProgram);
            }
            else
            {
                m_context.setVertexBufferAt(2, null);
                m_context.setVertexBufferAt(3, null);
                m_context.setProgram(m_fillProgram);
            }
        }

        /**
         * Draws the fills of one display tile.
         * @param size display tile size in tile pixels
         * @param stageX, stageY stage position of the tile pixel (0, 0)
         * @param stageScale stage pixels per tile pixel
         * @param clip stage rectangle of the display tile
         */
        public function drawTile(fills:Array, zoom:Number, size:Number, stageX:Number, stageY:Number,
                                 stageScale:Number, clip:Rectangle):void
        {
            var scissor:Rectangle = clip.intersection(m_view);
            if (scissor.width < 1 || scissor.height < 1)
            {
                return;
            }
            scissor.offset(-m_view.x, -m_view.y);
            m_context.setScissorRectangle(new Rectangle(Math.floor(scissor.x), Math.floor(scissor.y),
                Math.ceil(scissor.width), Math.ceil(scissor.height)));
            var list:Array = groups(fills);
            for (var g:int = 0; g < list.length; g++)
            {
                var group:Array = list[g];
                var mesh:Object = meshFor(group, zoom, g);
                if (mesh.chunks.length == 0)
                {
                    continue;
                }
                useProgram(mesh.line);
                var source:SourceTile = group[0].source;
                // tile units -> tile pixels -> stage -> clip space
                var k:Number = size * source.scale / mesh.extent;
                var ox:Number = -source.offsetX * size;
                var oy:Number = -source.offsetY * size;
                var sx:Number = k * stageScale * 2 / m_view.width;
                var sy:Number = -k * stageScale * 2 / m_view.height;
                var tx:Number = (stageX + ox * stageScale - m_view.x) * 2 / m_view.width - 1;
                var ty:Number = 1 - (stageY + oy * stageScale - m_view.y) * 2 / m_view.height;
                m_context.setProgramConstantsFromVector(Context3DProgramType.VERTEX, 0, Vector.<Number>([sx, sy, tx, ty]));
                if (mesh.line)
                {
                    m_context.setProgramConstantsFromVector(Context3DProgramType.VERTEX, 2,
                        Vector.<Number>([stageScale * 2 / m_view.width, -stageScale * 2 / m_view.height, k, 0.5]));
                }
                for each (var chunk:Object in mesh.chunks)
                {
                    if (mesh.line)
                    {
                        m_context.setVertexBufferAt(0, chunk.vertices, 0, Context3DVertexBufferFormat.FLOAT_2);
                        m_context.setVertexBufferAt(1, chunk.vertices, 2, Context3DVertexBufferFormat.FLOAT_2);
                        m_context.setVertexBufferAt(2, chunk.vertices, 4, Context3DVertexBufferFormat.FLOAT_4);
                        m_context.setVertexBufferAt(3, chunk.vertices, 8, Context3DVertexBufferFormat.BYTES_4);
                    }
                    else
                    {
                        m_context.setVertexBufferAt(0, chunk.vertices, 0, Context3DVertexBufferFormat.FLOAT_2);
                        m_context.setVertexBufferAt(1, chunk.vertices, 2, Context3DVertexBufferFormat.BYTES_4);
                    }
                    m_context.drawTriangles(chunk.indices, 0, chunk.triangles);
                }
                mesh.frame = m_frame;
            }
        }

        public function endFrame():void
        {
            m_context.setScissorRectangle(null);
            if (m_alpha < 1)
            {
                useProgram(false);
                // layer opacity: fade the whole frame towards white
                m_context.setProgramConstantsFromVector(Context3DProgramType.VERTEX, 0, Vector.<Number>([1, 1, 0, 0]));
                m_context.setProgramConstantsFromVector(Context3DProgramType.FRAGMENT, 0, Vector.<Number>([1, 1, 1, 1 - m_alpha]));
                m_context.setVertexBufferAt(0, m_veilVertices, 0, Context3DVertexBufferFormat.FLOAT_2);
                m_context.setVertexBufferAt(1, m_veilVertices, 2, Context3DVertexBufferFormat.BYTES_4);
                m_context.drawTriangles(m_veilIndices, 0, 2);
            }
            if (captureTarget != null)
            {
                m_context.drawToBitmapData(captureTarget);
                captureTarget = null;
            }
            m_context.present();
            if (m_frame % 120 == 0)
            {
                purgeMeshes();
            }
        }

        // ------------------------------------------------------------------
        // meshes
        // ------------------------------------------------------------------

        /**
         * Splits the items of a tile into runs drawn with one program and one data tile: consecutive
         * fills, or consecutive lines and outlines. The style order is kept between runs.
         */
        private static function groups(items:Array):Array
        {
            var result:Array = [];
            var current:Array = null;
            var currentLine:Boolean = false;
            for each (var item:Object in items)
            {
                var line:Boolean = item.kind != "fill";
                if (current == null || current[0].source.tile != item.source.tile || line != currentLine)
                {
                    current = [];
                    currentLine = line;
                    result.push(current);
                }
                current.push(item);
            }
            return result;
        }

        /** The mesh of a run of items of one data tile (cached per data tile, zoom and run). */
        private function meshFor(group:Array, zoom:Number, index:int):Object
        {
            var data:VectorTile = group[0].source.tile;
            var byZoom:Object = m_meshes[data];
            if (byZoom == null)
            {
                byZoom = m_meshes[data] = {};
            }
            var key:String = zoom + "#" + index + "#" + group.length;
            var mesh:Object = byZoom[key];
            if (mesh == null || mesh.generation != m_generation)
            {
                mesh = group[0].kind == "fill" ? buildMesh(group) : buildLineMesh(group);
                byZoom[key] = mesh;
            }
            return mesh;
        }

        private function buildMesh(group:Array):Object
        {
            var mesh:Object = {generation: m_generation, frame: m_frame, chunks: [], extent: 4096, line: false};
            var vertices:ByteArray = newVertexBytes();
            var indices:Vector.<uint> = new Vector.<uint>();
            var count:int = 0;
            for each (var fill:Object in group)
            {
                var b:LayerBucket = fill.bucket;
                var features:Vector.<MvtFeature> = b.features;
                for (var i:int = 0; i < features.length; i++)
                {
                    var feature:MvtFeature = features[i];
                    mesh.extent = feature.extent;
                    var rgb:uint;
                    var alpha:Number;
                    var opacity:Number = b.perFeature ? b.fillOpacities[i] : b.fillOpacity;
                    var pattern:String = b.perFeature ? b.patternNames[i] : b.patternName;
                    if (pattern != null)
                    {
                        // patterns are not textured yet: their average color
                        var average:Object = patternColor(pattern);
                        if (average == null)
                        {
                            continue;
                        }
                        rgb = average.rgb;
                        alpha = average.a * opacity * b.groupAlpha;
                    }
                    else
                    {
                        var color:StyleColor = b.perFeature ? b.fillColors[i] : b.fillColor;
                        if (color == null)
                        {
                            continue;
                        }
                        rgb = color.rgb;
                        alpha = color.a * opacity * b.groupAlpha;
                    }
                    if (alpha <= 0)
                    {
                        continue; // e.g. outline-only layers (outlines are not drawn on the GPU yet)
                    }
                    var r:int = (rgb >> 16) & 255;
                    var g:int = (rgb >> 8) & 255;
                    var bl:int = rgb & 255;
                    var a:int = Math.round(Math.min(1, alpha) * 255);
                    for each (var polygon:Object in polygons(feature.loadGeometry()))
                    {
                        var coords:Vector.<Number> = polygon.data;
                        var n:int = coords.length >> 1;
                        if (n < 3)
                        {
                            continue;
                        }
                        var triangles:Vector.<int> = Earcut.triangulate(coords, polygon.holes);
                        if (triangles.length == 0)
                        {
                            continue;
                        }
                        if (count + n > MAX_VERTICES)
                        {
                            addChunk(mesh, vertices, indices, count);
                            vertices = newVertexBytes();
                            indices = new Vector.<uint>();
                            count = 0;
                        }
                        for (var v:int = 0; v < n; v++)
                        {
                            vertices.writeFloat(coords[v * 2]);
                            vertices.writeFloat(coords[v * 2 + 1]);
                            vertices.writeByte(r);
                            vertices.writeByte(g);
                            vertices.writeByte(bl);
                            vertices.writeByte(a);
                        }
                        for (var t:int = 0; t < triangles.length; t++)
                        {
                            indices.push(count + triangles[t]);
                        }
                        count += n;
                    }
                }
            }
            addChunk(mesh, vertices, indices, count);
            return mesh;
        }

        // ------------------------------------------------------------------
        // line meshes
        // ------------------------------------------------------------------

        private var m_lineMesh:Object;
        private var m_lineVertices:ByteArray;
        private var m_lineIndices:Vector.<uint>;
        private var m_lineCount:int;

        /** Lines (line buckets) and polygon outlines (fill-outline-color) of a run, in order. */
        private function buildLineMesh(group:Array):Object
        {
            m_lineMesh = {generation: m_generation, frame: m_frame, chunks: [], extent: 4096, line: true};
            m_lineVertices = newVertexBytes();
            m_lineIndices = new Vector.<uint>();
            m_lineCount = 0;
            for each (var item:Object in group)
            {
                var b:LayerBucket = item.bucket;
                var features:Vector.<MvtFeature> = b.features;
                var outline:Boolean = item.kind == "outline";
                var miterLimit:Number = b.joints == JointStyle.MITER ? Math.max(1, b.miterLimit) : 1.5;
                var caps:Boolean = !outline && b.caps != CapsStyle.NONE;
                for (var i:int = 0; i < features.length; i++)
                {
                    var feature:MvtFeature = features[i];
                    m_lineMesh.extent = feature.extent;
                    var rgb:uint;
                    var alpha:Number;
                    var width:Number;
                    var period:Number = SOLID_PERIOD;
                    var on:Number = 1;
                    if (outline)
                    {
                        var color:StyleColor = b.perFeature ? b.outlineColors[i] : b.outlineColor;
                        var fillOpacity:Number = b.perFeature ? b.fillOpacities[i] : b.fillOpacity;
                        if (color == null || color.a <= 0)
                        {
                            // no outline color: like the CPU, an opaque fill gets a hairline of its own color
                            // (here it gives antialiased polygon edges)
                            color = b.perFeature ? b.fillColors[i] : b.fillColor;
                            var pattern:String = b.perFeature ? b.patternNames[i] : b.patternName;
                            if (!b.antialias || pattern != null || color == null || color.a * fillOpacity < 1)
                            {
                                continue;
                            }
                        }
                        rgb = color.rgb;
                        alpha = color.a * fillOpacity * b.groupAlpha;
                        width = 1;
                    }
                    else
                    {
                        rgb = b.perFeature ? b.lineRgbs[i] : b.lineRgb;
                        alpha = (b.perFeature ? b.lineAlphas[i] : b.lineAlpha) * b.groupAlpha;
                        width = b.perFeature ? b.lineWidths[i] : b.lineWidth;
                        var dashes:Array = b.dashes;
                        if (dashes != null && dashes.length >= 2 && width * (Number(dashes[0]) + Number(dashes[1])) >= 1.5)
                        {
                            // patterns of more than two values are approximated with the first dash and gap
                            var dash:Number = Math.max(0.01, Number(dashes[0]));
                            var gap:Number = Math.max(0.01, Number(dashes[1]));
                            period = (dash + gap) * width;
                            on = dash / (dash + gap);
                        }
                    }
                    if (alpha <= 0 || width <= 0)
                    {
                        continue;
                    }
                    var halfWidth:Number = Math.max(0.25, width) / 2; // thinner lines fade (coverage)
                    var color32:uint = ((rgb >> 16) & 255) | (((rgb >> 8) & 255) << 8) | ((rgb & 255) << 16) |
                                       (Math.round(Math.min(1, alpha) * 255) << 24);
                    for each (var part:Vector.<Number> in feature.loadGeometry())
                    {
                        addPolyline(part, halfWidth, period, on, color32, miterLimit, caps);
                    }
                }
            }
            flushLineChunk();
            var mesh:Object = m_lineMesh;
            m_lineMesh = null;
            m_lineVertices = null;
            m_lineIndices = null;
            return mesh;
        }

        private function flushLineChunk():void
        {
            addChunk(m_lineMesh, m_lineVertices, m_lineIndices, m_lineCount, 9);
            m_lineVertices = newVertexBytes();
            m_lineIndices = new Vector.<uint>();
            m_lineCount = 0;
        }

        /**
         * Appends one polyline as a triangle strip: two vertices per point, extruded on both sides by the
         * shader. Joins: miter up to miterLimit, otherwise bevel; caps: extended by half the width when the
         * style asks for round or square caps (round is approximated).
         */
        private function addPolyline(part:Vector.<Number>, halfWidth:Number, period:Number, on:Number,
                                     color32:uint, miterLimit:Number, caps:Boolean):void
        {
            // drop repeated points
            var xs:Vector.<Number> = new Vector.<Number>();
            var ys:Vector.<Number> = new Vector.<Number>();
            for (var i:int = 0; i + 1 < part.length; i += 2)
            {
                var x:Number = part[i];
                var y:Number = part[i + 1];
                var last:int = xs.length - 1;
                if (last < 0 || xs[last] != x || ys[last] != y)
                {
                    xs.push(x);
                    ys.push(y);
                }
            }
            var n:int = xs.length;
            if (n < 2)
            {
                return;
            }
            if (4 * n > MAX_VERTICES)
            {
                // very long line: split it (the pieces share their end point)
                var half:int = n >> 1;
                addPolyline(part.slice(0, (half + 1) * 2), halfWidth, period, on, color32, miterLimit, caps);
                addPolyline(part.slice(half * 2), halfWidth, period, on, color32, miterLimit, caps);
                return;
            }
            if (m_lineCount + 4 * n > MAX_VERTICES)
            {
                flushLineChunk();
            }
            var distance:Number = 0;
            m_previous = -1;
            for (i = 0; i < n; i++)
            {
                var inX:Number = 0;
                var inY:Number = 0;
                var outX:Number = 0;
                var outY:Number = 0;
                var length:Number;
                if (i > 0)
                {
                    inX = xs[i] - xs[i - 1];
                    inY = ys[i] - ys[i - 1];
                    length = Math.sqrt(inX * inX + inY * inY);
                    distance += length;
                    inX /= length;
                    inY /= length;
                }
                if (i < n - 1)
                {
                    outX = xs[i + 1] - xs[i];
                    outY = ys[i + 1] - ys[i];
                    length = Math.sqrt(outX * outX + outY * outY);
                    outX /= length;
                    outY /= length;
                }
                if (i == 0)
                {
                    // start: normal of the first segment, optional cap backwards
                    pair(xs[i], ys[i], -outY, outX, caps ? -outX : 0, caps ? -outY : 0, halfWidth, distance, period, on, color32);
                }
                else if (i == n - 1)
                {
                    pair(xs[i], ys[i], -inY, inX, caps ? inX : 0, caps ? inY : 0, halfWidth, distance, period, on, color32);
                }
                else
                {
                    var mx:Number = -inY - outY;
                    var my:Number = inX + outX;
                    var ml:Number = Math.sqrt(mx * mx + my * my);
                    var scale:Number = 0;
                    if (ml > 1e-6)
                    {
                        mx /= ml;
                        my /= ml;
                        var cos:Number = mx * -inY + my * inX;
                        scale = cos > 1e-6 ? 1 / cos : 0;
                    }
                    if (scale > 0 && scale <= miterLimit)
                    {
                        pair(xs[i], ys[i], mx * scale, my * scale, 0, 0, halfWidth, distance, period, on, color32);
                    }
                    else
                    {
                        // bevel: end the incoming segment and start the outgoing one at the same point
                        pair(xs[i], ys[i], -inY, inX, 0, 0, halfWidth, distance, period, on, color32);
                        pair(xs[i], ys[i], -outY, outX, 0, 0, halfWidth, distance, period, on, color32);
                    }
                }
            }
        }

        /** Index of the left vertex of the previous pair of the current polyline, or -1. */
        private var m_previous:int = -1;

        /** Appends the left and right vertices of a point (normal nx, ny; tangent offset tx, ty for caps). */
        private function pair(x:Number, y:Number, nx:Number, ny:Number, tx:Number, ty:Number, halfWidth:Number,
                              distance:Number, period:Number, on:Number, color32:uint):void
        {
            var v:ByteArray = m_lineVertices;
            for (var side:int = 1; side >= -1; side -= 2)
            {
                v.writeFloat(x);
                v.writeFloat(y);
                v.writeFloat(nx * side + tx);
                v.writeFloat(ny * side + ty);
                v.writeFloat(halfWidth * side);
                v.writeFloat(distance);
                v.writeFloat(period);
                v.writeFloat(on);
                v.writeUnsignedInt(color32);
            }
            var left:int = m_lineCount;
            if (m_previous >= 0)
            {
                m_lineIndices.push(m_previous, m_previous + 1, left, m_previous + 1, left + 1, left);
            }
            m_previous = left;
            m_lineCount += 2;
        }

        /** Average color (alpha weighted) of a sprite, or null when unknown. */
        private function patternColor(name:String):Object
        {
            if (m_patternColors.hasOwnProperty(name))
            {
                return m_patternColors[name];
            }
            var result:Object = null;
            var image:BitmapData = sprites != null ? sprites.getImage(name) : null;
            if (image != null)
            {
                var pixels:Vector.<uint> = image.getVector(image.rect);
                var r:Number = 0;
                var g:Number = 0;
                var b:Number = 0;
                var weight:Number = 0;
                for each (var p:uint in pixels)
                {
                    var a:Number = (p >>> 24) / 255;
                    r += ((p >> 16) & 255) * a;
                    g += ((p >> 8) & 255) * a;
                    b += (p & 255) * a;
                    weight += a;
                }
                if (weight > 0)
                {
                    result = {rgb: (Math.round(r / weight) << 16) | (Math.round(g / weight) << 8) | Math.round(b / weight),
                              a: weight / pixels.length};
                }
            }
            m_patternColors[name] = result;
            return result;
        }

        /** Vertex layout: x, y (float, little endian), color r, g, b, a (bytes). */
        private static function newVertexBytes():ByteArray
        {
            var bytes:ByteArray = new ByteArray();
            bytes.endian = Endian.LITTLE_ENDIAN;
            return bytes;
        }

        private function addChunk(mesh:Object, vertices:ByteArray, indices:Vector.<uint>, count:int,
                                  data32PerVertex:int = 3):void
        {
            if (count == 0 || indices.length == 0)
            {
                return;
            }
            var vb:VertexBuffer3D = m_context.createVertexBuffer(count, data32PerVertex);
            vb.uploadFromByteArray(vertices, 0, 0, count);
            var ib:IndexBuffer3D = m_context.createIndexBuffer(indices.length);
            ib.uploadFromVector(indices, 0, indices.length);
            mesh.chunks.push({vertices: vb, indices: ib, triangles: indices.length / 3});
        }

        /**
         * Splits the rings of a polygon feature into polygons (outer ring + holes), using the winding
         * order like the vector tile specification: rings with the orientation of the first one start a
         * new polygon, the others are holes of the current one.
         */
        private static function polygons(rings:Array):Array
        {
            var result:Array = [];
            var current:Object = null;
            var outerSign:int = 0;
            for each (var ring:Vector.<Number> in rings)
            {
                var n:int = ring.length;
                if (n < 6)
                {
                    continue;
                }
                var area:Number = 0;
                for (var i:int = 0, j:int = n - 2; i < n; i += 2)
                {
                    area += (ring[j] - ring[i]) * (ring[i + 1] + ring[j + 1]);
                    j = i;
                }
                if (area == 0)
                {
                    continue;
                }
                var s:int = area > 0 ? 1 : -1;
                if (outerSign == 0)
                {
                    outerSign = s;
                }
                if (s == outerSign || current == null)
                {
                    current = {data: ring.concat(), holes: null};
                    result.push(current);
                }
                else
                {
                    if (current.holes == null)
                    {
                        current.holes = new Vector.<int>();
                    }
                    current.holes.push(current.data.length >> 1);
                    current.data = current.data.concat(ring);
                }
            }
            return result;
        }

        /** Releases the meshes not drawn for a while (their tiles left the view or the cache). */
        private function purgeMeshes():void
        {
            for (var data:Object in m_meshes)
            {
                var byZoom:Object = m_meshes[data];
                var alive:Boolean = false;
                for (var key:String in byZoom)
                {
                    var mesh:Object = byZoom[key];
                    if (m_frame - mesh.frame > MESH_TTL_FRAMES || mesh.generation != m_generation)
                    {
                        disposeMesh(mesh);
                        delete byZoom[key];
                    }
                    else
                    {
                        alive = true;
                    }
                }
                if (!alive)
                {
                    delete m_meshes[data];
                }
            }
        }

        private function disposeMeshes():void
        {
            for each (var byZoom:Object in m_meshes)
            {
                for each (var mesh:Object in byZoom)
                {
                    disposeMesh(mesh);
                }
            }
            m_meshes = new Dictionary();
        }

        private function disposeMesh(mesh:Object):void
        {
            if (mesh.generation != m_generation)
            {
                return; // created on a lost context: already gone
            }
            for each (var chunk:Object in mesh.chunks)
            {
                chunk.vertices.dispose();
                chunk.indices.dispose();
            }
            mesh.chunks = [];
        }
    }
}
