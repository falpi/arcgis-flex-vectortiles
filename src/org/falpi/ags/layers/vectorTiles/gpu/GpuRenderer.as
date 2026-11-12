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
    import flash.display3D.Context3DCompareMode;
    import flash.display3D.Context3DProgramType;
    import flash.display3D.Context3DStencilAction;
    import flash.display3D.Context3DTriangleFace;
    import flash.display3D.Context3DVertexBufferFormat;
    import flash.display3D.IndexBuffer3D;
    import flash.display3D.Program3D;
    import flash.display3D.VertexBuffer3D;
    import flash.events.ErrorEvent;
    import flash.events.Event;
    import flash.geom.Rectangle;
    import flash.utils.Dictionary;
    import flash.utils.getTimer;

    /**
     * Draws prepared buckets with Stage3D, under the whole display list. One instance per layer;
     * the first Stage3D of the stage is used by one renderer at a time.
     *
     * - One mesh per data tile and zoom holds its fills, lines and outlines in style order (a single
     *   program and vertex format), so a data tile costs one draw call per frame however many display
     *   tiles are cut from it (overzoom): the scissor is the union of their rectangles.
     * - Meshes keep the geometry in tile extent units; each draw maps them to clip space with constants.
     * - Meshes are built incrementally (a time budget per call) and kept within a memory budget: the
     *   least recently used ones are released first.
     * - Nothing is drawn or presented when the frame would be identical to the previous one.
     */
    public final class GpuRenderer
    {
        /** x, y, extrusion x, y | signed edge distance, line distance, dash period, dash on | r, g, b, a. */
        private static const FLOATS:int = 12;
        private static const BYTES_PER_VERTEX:int = 48;
        private static const MAX_VERTICES:int = 65535;
        private static const STRIP_POINTS:int = 16000;
        /** Vertex + index memory kept on the GPU (Stage3D allows 256 MB of vertex buffers). */
        private static const BUDGET_BYTES:Number = 144 * 1048576;
        private static const MAX_BUFFERS:int = 3000;
        private static const MESH_TTL_MS:int = 12000;
        /** Time per frame spent rebuilding meshes missing at draw time (lost context, eviction). */
        private static const REBUILD_BUDGET_MS:int = 8;
        /** Dash period of solid lines: never reaches the gap. */
        private static const SOLID_PERIOD:Number = 1e9;

        private static var s_owners:Dictionary = new Dictionary(true);
        /** Called (once) when a renderer releases its Stage3D: layers waiting to use it. */
        private static var s_waiting:Array = [];
        private static var s_ids:int = 0;
        private static var s_groups:int = 0;
        /** Features above these sizes are filled through the stencil buffer instead of being triangulated. */
        public static var fanVertices:int = 3000;
        public static var fanRings:int = 64;

        /**
         * va0 (x, y in tile units, extrusion direction), va1 (e = signed distance from the center line at the
         * vertex in pixels, antialiasing margin included; distance along the line in tile units; dash period
         * in pixels; dash "on" fraction, 2 for fills), va2 color.
         * vc0 tile units -> clip, vc1 (0,0,0,1), vc2 (pixels -> clip x, pixels -> clip y, tile units -> pixels, 0).
         * Antialiasing does not rely on multisampling: strips are half a pixel wider on each side and the
         * fragment alpha is the coverage computed from the distance to the center line.
         */
        private static const VERTEX:String =
            "mov vt0, vc1\n" +
            "mul vt0.xy, va0.xy, vc0.xy\n" +        // position -> clip space
            "add vt0.xy, vt0.xy, vc0.zw\n" +
            "abs vt3, va1\n" +                      // vt3.x = |e|: extrusion in pixels (0 for fills)
            "mul vt1.xy, va0.zw, vt3.xx\n" +
            "mul vt1.xy, vt1.xy, vc2.xy\n" +        // -> clip space (constant width on screen)
            "add vt0.xy, vt0.xy, vt1.xy\n" +
            "mov op, vt0\n" +
            "mov v0, va2\n" +
            "mov vt2, vc1\n" +
            "mul vt2.x, va1.y, vc2.z\n" +           // line distance in pixels
            "div vt2.x, vt2.x, va1.z\n" +           // in dash periods
            "mov vt2.y, va1.w\n" +                  // "on" fraction
            "mov v1, vt2\n" +
            "sub vt4, va1.wwww, vc1.wwww\n" +       // on - 1: 1 for fills, <= 0 for lines
            "sat vt4, vt4\n" +
            "add vt4.y, vt4.x, vt3.x\n" +           // half width + margin (1 for fills)
            "mov vt4.x, va1.x\n" +                  // signed distance from the center (0 for fills)
            "mov v2, vt4\n";
        private static const FRAGMENT:String =
            "frc ft0.x, v1.x\n" +                   // position inside the dash period
            "sub ft0.y, v1.y, ft0.x\n" +            // negative in the gap
            "kil ft0.y\n" +
            "abs ft1.x, v2.x\n" +
            "sub ft1.x, v2.y, ft1.x\n" +            // coverage: 0.5 at the true edge
            "sat ft1.x, ft1.x\n" +
            "mul ft2, v0, fc0\n" +                  // fc0: color multiplier
            "mul ft2.w, ft2.w, ft1.x\n" +
            "mov oc, ft2\n";

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

        /**
         * Splits the GPU items of a display tile ({bucket, source, kind} in drawing order) into groups
         * drawn with one mesh: consecutive items of the same data tile (one group for single source styles).
         * Returns an Array of {items, source}.
         */
        public static function groups(items:Array):Array
        {
            var result:Array = [];
            var current:Object = null;
            for each (var item:Object in items)
            {
                if (current == null || current.source.tile != item.source.tile)
                {
                    current = {items: [], source: item.source, mesh: null};
                    result.push(current);
                }
                current.items.push(item);
            }
            return result;
        }

        private var m_stage:Stage;
        private var m_stage3D:Stage3D;
        private var m_context:Context3D;
        private var m_program:Program3D;
        private var m_quadVertices:VertexBuffer3D;
        private var m_quadIndices:IndexBuffer3D;
        private var m_generation:int = 0;
        private var m_onState:Function;

        private var m_bufferWidth:int;
        private var m_bufferHeight:int;
        private var m_viewX:Number = 0;
        private var m_viewY:Number = 0;
        private var m_viewWidth:Number = 0;
        private var m_viewHeight:Number = 0;
        private var m_frame:int = 0;
        private var m_now:int = 0;
        private var m_lastPurge:int = 0;

        /** VectorTile -> {zoom#group -> GpuMesh}. */
        private var m_meshes:Dictionary = new Dictionary();
        private var m_meshCount:int = 0;
        private var m_bytes:Number = 0;
        private var m_buffers:int = 0;
        /** The mesh being built (the working vectors below hold its current chunk). */
        private var m_building:GpuMesh;
        private var m_v:Vector.<Number> = new Vector.<Number>();
        private var m_i:Vector.<uint> = new Vector.<uint>();
        private var m_vn:int = 0;
        private var m_in:int = 0;
        private var m_count:int = 0;
        private var m_previous:int = -1;
        private var m_xs:Vector.<Number> = new Vector.<Number>();
        private var m_ys:Vector.<Number> = new Vector.<Number>();

        /** Meshes drawn in the current frame, in order. */
        private var m_records:Vector.<GpuMesh> = new Vector.<GpuMesh>();
        private var m_recordCount:int = 0;
        private var m_signature:Vector.<Number> = new Vector.<Number>();
        private var m_lastSignature:Vector.<Number> = new Vector.<Number>();
        private var m_c0:Vector.<Number> = new Vector.<Number>(4, true);
        private var m_c1:Vector.<Number> = Vector.<Number>([0, 0, 0, 1]);
        private var m_c2:Vector.<Number> = new Vector.<Number>(4, true);
        private var m_fc:Vector.<Number> = new Vector.<Number>(4, true);
        private var m_scissor:Rectangle = new Rectangle();

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
        /** Diagnostics: frames actually drawn / skipped because identical. */
        /** Diagnostics: the feature that took longest to add to a mesh. */
        public var slowestFeatureMs:int = 0;
        public var slowestFeature:String = "";
        /** Diagnostics: errors met while building meshes (count and last message). */
        public var errors:int = 0;
        public var lastError:String = "";
        public var framesDrawn:int = 0;
        public var framesSkipped:int = 0;

        /** @param onState called with no arguments when available or failure change. */
        public function GpuRenderer(stage:Stage, onState:Function)
        {
            m_stage = stage;
            m_onState = onState;
        }

        /** Diagnostics: meshes and GPU memory in use. */
        public function get stats():String
        {
            return m_meshCount + " meshes, " + (m_bytes / 1048576).toFixed(1) + " MB, " + m_buffers + " buffers, frames " +
                   framesDrawn + " drawn/" + framesSkipped + " skipped, slowest feature " + slowestFeatureMs + " ms (" +
                   slowestFeature + "), errors " + errors + (errors > 0 ? " (" + lastError + ")" : "");
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
                try
                {
                    m_context.dispose();
                }
                catch (error:Error)
                {
                }
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
            m_meshCount = 0;
            m_bytes = 0;
            m_buffers = 0;
            m_building = null;
            m_bufferWidth = 0;
            m_bufferHeight = 0;
            m_lastSignature.length = 0;
            try
            {
                m_context.enableErrorChecking = false;
                m_program = m_context.createProgram();
                m_program.upload(Agal.assemble(false, VERTEX), Agal.assemble(true, FRAGMENT));
                m_context.setBlendFactors(Context3DBlendFactor.SOURCE_ALPHA, Context3DBlendFactor.ONE_MINUS_SOURCE_ALPHA);
                createQuad();
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

        /** Full screen white quad (clip space): tile background and the final fade for the layer opacity. */
        private function createQuad():void
        {
            var data:Vector.<Number> = new Vector.<Number>();
            for each (var corner:Array in [[-1, -1], [1, -1], [1, 1], [-1, 1]])
            {
                data.push(corner[0], corner[1], 0, 0, 0, 0, SOLID_PERIOD, 2, 1, 1, 1, 1);
            }
            m_quadVertices = m_context.createVertexBuffer(4, FLOATS);
            m_quadVertices.uploadFromVector(data, 0, 4);
            m_quadIndices = m_context.createIndexBuffer(6);
            m_quadIndices.uploadFromVector(Vector.<uint>([0, 1, 2, 0, 2, 3]), 0, 6);
        }

        // ------------------------------------------------------------------
        // frame
        // ------------------------------------------------------------------

        /** Hides the Stage3D layer (the map is not on screen). */
        public function hide():void
        {
            if (m_stage3D != null && m_stage3D.visible)
            {
                m_stage3D.visible = false;
                m_lastSignature.length = 0;
            }
        }

        private function get usable():Boolean
        {
            return available && m_context != null && m_context.driverInfo != "Disposed";
        }

        /**
         * Builds the meshes of a display tile, until the deadline (getTimer value).
         * @param tileGroups result of groups() for the tile
         * @return true when the tile can be drawn (meshes ready, or not buildable for now)
         */
        public function prepare(tileGroups:Array, zoom:Number, deadline:int):Boolean
        {
            if (!usable)
            {
                return true;
            }
            m_now = getTimer();
            for (var g:int = 0; g < tileGroups.length; g++)
            {
                var mesh:GpuMesh = resolve(tileGroups[g], zoom, g);
                if (!mesh.ready && !mesh.failed)
                {
                    if (!canBuild(mesh))
                    {
                        return false;
                    }
                    buildStep(mesh, deadline);
                    if (!mesh.ready && !mesh.failed)
                    {
                        return false;
                    }
                }
            }
            return true;
        }

        /**
         * Draws a frame over the given stage rectangle (the map).
         * @param alpha effective opacity of the layer: applied at the end by fading towards white, like the
         *        CPU tiles over the (white) map container
         * @param entries display tiles in drawing order: {groups, zoom, size, x, y, scale, width, height}
         *        (stage position of the tile, stage pixels per tile pixel, stage size); only the first
         *        count entries are used
         */
        public function render(viewX:Number, viewY:Number, viewWidth:Number, viewHeight:Number, background:StyleColor,
                               alpha:Number, entries:Array, count:int):void
        {
            if (!usable)
            {
                return;
            }
            var width:int = Math.round(viewWidth);
            var height:int = Math.round(viewHeight);
            if (width < 32 || height < 32)
            {
                hide();
                return;
            }
            m_now = getTimer();
            m_frame++;
            alpha = alpha < 0 ? 0 : (alpha > 1 ? 1 : alpha);
            m_viewX = Math.round(viewX);
            m_viewY = Math.round(viewY);
            m_viewWidth = width;
            m_viewHeight = height;
            if (m_stage3D.x != m_viewX || m_stage3D.y != m_viewY)
            {
                m_stage3D.x = m_viewX;
                m_stage3D.y = m_viewY;
            }
            if (!m_stage3D.visible)
            {
                m_stage3D.visible = true;
                m_lastSignature.length = 0;
            }
            if (width != m_bufferWidth || height != m_bufferHeight)
            {
                m_context.configureBackBuffer(width, height, 4, true); // stencil for the even-odd fills
                m_bufferWidth = width;
                m_bufferHeight = height;
                m_lastSignature.length = 0;
            }

            // what to draw: one record per mesh, with the union of the rectangles of its display tiles
            var deadline:int = m_now + REBUILD_BUDGET_MS;
            var right:Number = m_viewX + m_viewWidth;
            var bottom:Number = m_viewY + m_viewHeight;
            m_recordCount = 0;
            for (var e:int = 0; e < count; e++)
            {
                var entry:Object = entries[e];
                var tileGroups:Array = entry.groups;
                var l:Number = entry.x > m_viewX ? entry.x : m_viewX;
                var t:Number = entry.y > m_viewY ? entry.y : m_viewY;
                var r:Number = entry.x + entry.width < right ? entry.x + entry.width : right;
                var b:Number = entry.y + entry.height < bottom ? entry.y + entry.height : bottom;
                if (r - l < 1 || b - t < 1)
                {
                    continue;
                }
                for (var g:int = 0; g < tileGroups.length; g++)
                {
                    var group:Object = tileGroups[g];
                    var mesh:GpuMesh = resolve(group, entry.zoom, g);
                    if (!mesh.ready)
                    {
                        // missing at draw time (lost context, eviction): rebuilt a little per frame
                        if (mesh.failed && m_now - mesh.failedAt > 3000)
                        {
                            mesh.failed = false;
                        }
                        if (!mesh.failed && canBuild(mesh))
                        {
                            buildStep(mesh, deadline);
                        }
                        if (!mesh.ready)
                        {
                            continue;
                        }
                    }
                    if (mesh.chunks.length == 0)
                    {
                        continue;
                    }
                    if (mesh.recordFrame != m_frame)
                    {
                        mesh.recordFrame = m_frame;
                        var source:SourceTile = group.source;
                        var size:Number = entry.size;
                        var scale:Number = entry.scale;
                        // tile units -> tile pixels -> stage -> clip space
                        var k:Number = size * source.scale / mesh.extent;
                        mesh.k = k;
                        mesh.scale = scale;
                        mesh.sx = k * scale * 2 / m_viewWidth;
                        mesh.sy = -k * scale * 2 / m_viewHeight;
                        mesh.tx = (entry.x - source.offsetX * size * scale - m_viewX) * 2 / m_viewWidth - 1;
                        mesh.ty = 1 - (entry.y - source.offsetY * size * scale - m_viewY) * 2 / m_viewHeight;
                        mesh.left = l;
                        mesh.top = t;
                        mesh.right = r;
                        mesh.bottom = b;
                        mesh.clearUnder = g == 0;
                        m_records[m_recordCount++] = mesh;
                    }
                    else
                    {
                        if (l < mesh.left) mesh.left = l;
                        if (t < mesh.top) mesh.top = t;
                        if (r > mesh.right) mesh.right = r;
                        if (b > mesh.bottom) mesh.bottom = b;
                    }
                }
            }

            // identical to the frame on screen: nothing to do
            var bg:uint = background != null ? background.rgb : 0xFFFFFF;
            var sig:Vector.<Number> = m_signature;
            var n:int = 0;
            sig[n++] = m_viewX; sig[n++] = m_viewY; sig[n++] = width; sig[n++] = height;
            sig[n++] = alpha; sig[n++] = bg; sig[n++] = m_generation;
            var i:int;
            for (i = 0; i < m_recordCount; i++)
            {
                mesh = m_records[i];
                sig[n++] = mesh.id; sig[n++] = mesh.sx; sig[n++] = mesh.sy; sig[n++] = mesh.tx; sig[n++] = mesh.ty;
                sig[n++] = mesh.left; sig[n++] = mesh.top; sig[n++] = mesh.right; sig[n++] = mesh.bottom;
            }
            sig.length = n;
            var same:Boolean = captureTarget == null && n == m_lastSignature.length;
            for (i = 0; same && i < n; i++)
            {
                same = sig[i] == m_lastSignature[i];
            }
            if (m_now - m_lastPurge > 2000)
            {
                m_lastPurge = m_now;
                purge();
            }
            if (same)
            {
                framesSkipped++;
                return;
            }
            m_signature = m_lastSignature;
            m_lastSignature = sig;
            framesDrawn++;

            var bgR:Number = ((bg >> 16) & 255) / 255;
            var bgG:Number = ((bg >> 8) & 255) / 255;
            var bgB:Number = (bg & 255) / 255;
            m_context.clear(bgR, bgG, bgB, 1);
            m_context.setProgram(m_program);
            m_context.setDepthTest(false, Context3DCompareMode.ALWAYS);
            m_context.setProgramConstantsFromVector(Context3DProgramType.VERTEX, 1, m_c1);
            for (i = 0; i < m_recordCount; i++)
            {
                mesh = m_records[i];
                m_scissor.x = Math.floor(mesh.left - m_viewX);
                m_scissor.y = Math.floor(mesh.top - m_viewY);
                m_scissor.width = Math.ceil(mesh.right - m_viewX) - m_scissor.x;
                m_scissor.height = Math.ceil(mesh.bottom - m_viewY) - m_scissor.y;
                m_context.setScissorRectangle(m_scissor);
                if (mesh.clearUnder)
                {
                    // hides the tiles of another level kept underneath as placeholders
                    drawQuad(bgR, bgG, bgB, 1);
                }
                m_c0[0] = mesh.sx; m_c0[1] = mesh.sy; m_c0[2] = mesh.tx; m_c0[3] = mesh.ty;
                m_c2[0] = mesh.scale * 2 / m_viewWidth; m_c2[1] = -mesh.scale * 2 / m_viewHeight; m_c2[2] = mesh.k; m_c2[3] = 0;
                m_fc[0] = 1; m_fc[1] = 1; m_fc[2] = 1; m_fc[3] = 1;
                m_context.setProgramConstantsFromVector(Context3DProgramType.VERTEX, 0, m_c0);
                m_context.setProgramConstantsFromVector(Context3DProgramType.VERTEX, 2, m_c2);
                m_context.setProgramConstantsFromVector(Context3DProgramType.FRAGMENT, 0, m_fc);
                var chunks:Array = mesh.chunks;
                var numChunks:int = chunks.length;
                var c:int = 0;
                while (c < numChunks)
                {
                    var chunk:GpuChunk = chunks[c];
                    if (chunk.group == 0)
                    {
                        drawChunk(chunk);
                        c++;
                        continue;
                    }
                    // even-odd fill of the fans of one feature: count the coverage in the stencil buffer,
                    // then paint (and reset) the pixels covered an odd number of times
                    var last:int = c;
                    while (last + 1 < numChunks && GpuChunk(chunks[int(last + 1)]).group == chunk.group)
                    {
                        last++;
                    }
                    var s:int;
                    m_context.setColorMask(false, false, false, false);
                    m_context.setStencilReferenceValue(0);
                    m_context.setStencilActions(Context3DTriangleFace.FRONT_AND_BACK, Context3DCompareMode.ALWAYS,
                        Context3DStencilAction.INVERT, Context3DStencilAction.INVERT, Context3DStencilAction.INVERT);
                    for (s = c; s <= last; s++)
                    {
                        drawChunk(chunks[s]);
                    }
                    m_context.setColorMask(true, true, true, true);
                    m_context.setStencilActions(Context3DTriangleFace.FRONT_AND_BACK, Context3DCompareMode.NOT_EQUAL,
                        Context3DStencilAction.ZERO, Context3DStencilAction.ZERO, Context3DStencilAction.KEEP);
                    for (s = c; s <= last; s++)
                    {
                        drawChunk(chunks[s]);
                    }
                    m_context.setStencilActions(Context3DTriangleFace.FRONT_AND_BACK, Context3DCompareMode.ALWAYS,
                        Context3DStencilAction.KEEP, Context3DStencilAction.KEEP, Context3DStencilAction.KEEP);
                    c = last + 1;
                }
            }
            m_context.setScissorRectangle(null);
            if (alpha < 1)
            {
                // layer opacity: fade the whole frame towards white
                drawQuad(1, 1, 1, 1 - alpha);
            }
            if (captureTarget != null)
            {
                m_context.drawToBitmapData(captureTarget);
                captureTarget = null;
            }
            m_context.present();
        }

        private function drawChunk(chunk:GpuChunk):void
        {
            m_context.setVertexBufferAt(0, chunk.vertices, 0, Context3DVertexBufferFormat.FLOAT_4);
            m_context.setVertexBufferAt(1, chunk.vertices, 4, Context3DVertexBufferFormat.FLOAT_4);
            m_context.setVertexBufferAt(2, chunk.vertices, 8, Context3DVertexBufferFormat.FLOAT_4);
            m_context.drawTriangles(chunk.indices, 0, chunk.triangles);
        }

        private function drawQuad(r:Number, g:Number, b:Number, a:Number):void
        {
            m_c0[0] = 1; m_c0[1] = 1; m_c0[2] = 0; m_c0[3] = 0;
            m_fc[0] = r; m_fc[1] = g; m_fc[2] = b; m_fc[3] = a;
            m_context.setProgramConstantsFromVector(Context3DProgramType.VERTEX, 0, m_c0);
            m_context.setProgramConstantsFromVector(Context3DProgramType.FRAGMENT, 0, m_fc);
            m_context.setVertexBufferAt(0, m_quadVertices, 0, Context3DVertexBufferFormat.FLOAT_4);
            m_context.setVertexBufferAt(1, m_quadVertices, 4, Context3DVertexBufferFormat.FLOAT_4);
            m_context.setVertexBufferAt(2, m_quadVertices, 8, Context3DVertexBufferFormat.FLOAT_4);
            m_context.drawTriangles(m_quadIndices, 0, 2);
        }

        // ------------------------------------------------------------------
        // mesh cache
        // ------------------------------------------------------------------

        /** The mesh of a group (created empty when missing) marked as used now. */
        private function resolve(group:Object, zoom:Number, index:int):GpuMesh
        {
            var mesh:GpuMesh = group.mesh;
            if (mesh == null || mesh.disposed || mesh.generation != m_generation)
            {
                var data:VectorTile = group.source.tile;
                var byKey:Object = m_meshes[data];
                if (byKey == null)
                {
                    byKey = m_meshes[data] = {};
                }
                var key:String = zoom + "#" + index;
                mesh = byKey[key];
                if (mesh == null || mesh.disposed || mesh.generation != m_generation)
                {
                    mesh = new GpuMesh();
                    mesh.id = ++s_ids;
                    mesh.generation = m_generation;
                    mesh.items = group.items;
                    byKey[key] = mesh;
                    m_meshCount++;
                }
                group.mesh = mesh;
            }
            mesh.used = m_now;
            mesh.frame = m_frame;
            return mesh;
        }

        /** Only one mesh is built at a time (shared working buffers); an abandoned build gives way. */
        private function canBuild(mesh:GpuMesh):Boolean
        {
            if (m_building == null || m_building == mesh)
            {
                return true;
            }
            if (m_building.disposed || m_building.ready || m_now - m_building.used > 500)
            {
                if (!m_building.ready)
                {
                    release(m_building); // its tile is gone: start again if it comes back
                }
                m_building = null;
                return true;
            }
            return false;
        }

        /** Releases the GPU buffers of a mesh; it is rebuilt if needed again. */
        private function release(mesh:GpuMesh):void
        {
            if (mesh.disposed)
            {
                return;
            }
            mesh.disposed = true;
            m_meshCount--;
            if (mesh.generation == m_generation)
            {
                for each (var chunk:GpuChunk in mesh.chunks)
                {
                    try
                    {
                        chunk.vertices.dispose();
                        chunk.indices.dispose();
                    }
                    catch (error:Error)
                    {
                    }
                    m_bytes -= chunk.bytes;
                    m_buffers -= 2;
                }
            }
            mesh.chunks = [];
            mesh.items = null;
            if (m_building == mesh)
            {
                m_building = null;
            }
        }

        /** Releases the meshes not used for a while and drops the released ones from the cache. */
        private function purge():void
        {
            for (var data:Object in m_meshes)
            {
                var byKey:Object = m_meshes[data];
                var alive:Boolean = false;
                for (var key:String in byKey)
                {
                    var mesh:GpuMesh = byKey[key];
                    if (!mesh.disposed && mesh != m_building && m_now - mesh.used > MESH_TTL_MS)
                    {
                        release(mesh);
                    }
                    if (mesh.disposed)
                    {
                        delete byKey[key];
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

        /**
         * Makes room for a new chunk: releases the least recently used meshes that are not on screen
         * until the budget is respected (or all of them when everything is true).
         */
        private function makeRoom(bytes:Number, everything:Boolean):void
        {
            while (everything || m_bytes + bytes > BUDGET_BYTES || m_buffers + 2 > MAX_BUFFERS)
            {
                var oldest:GpuMesh = null;
                for each (var byKey:Object in m_meshes)
                {
                    for each (var mesh:GpuMesh in byKey)
                    {
                        if (!mesh.disposed && mesh != m_building && mesh.frame < m_frame - 1 && m_now - mesh.used > 250 &&
                            (oldest == null || mesh.used < oldest.used))
                        {
                            oldest = mesh;
                        }
                    }
                }
                if (oldest == null)
                {
                    return; // everything left is on screen
                }
                release(oldest);
            }
        }

        private function disposeMeshes():void
        {
            for each (var byKey:Object in m_meshes)
            {
                for each (var mesh:GpuMesh in byKey)
                {
                    release(mesh);
                }
            }
            m_meshes = new Dictionary();
            m_building = null;
        }

        // ------------------------------------------------------------------
        // mesh building
        // ------------------------------------------------------------------

        /** Continues building a mesh until it is ready or the deadline (getTimer value) passes. */
        private function buildStep(mesh:GpuMesh, deadline:int):void
        {
            if (m_building != mesh)
            {
                m_building = mesh;
                m_vn = 0;
                m_in = 0;
                m_count = 0;
            }
            var items:Array = mesh.items;
            try
            {
                while (mesh.itemIndex < items.length)
                {
                    var item:Object = items[mesh.itemIndex];
                    var b:LayerBucket = item.bucket;
                    var features:Vector.<MvtFeature> = b.features;
                    var total:int = features.length;
                    var kind:String = item.kind;
                    var miterLimit:Number = b.joints == JointStyle.MITER ? Math.max(1, b.miterLimit) : 1.5;
                    var caps:Boolean = kind == "line" && b.caps != CapsStyle.NONE;
                    while (mesh.featureIndex < total)
                    {
                        var index:int = mesh.featureIndex++;
                        var feature:MvtFeature = features[index];
                        var began:int = getTimer();
                        try
                        {
                            if (kind == "fill")
                            {
                                addFill(mesh, b, index, feature);
                            }
                            else
                            {
                                addLines(mesh, b, index, feature, kind == "outline", miterLimit, caps);
                            }
                        }
                        catch (featureError:RangeError)
                        {
                            // a broken geometry must not stop the tile
                            errors++;
                            lastError = "feature " + kind + " " + b.layer.id + " #" + index + ": " + featureError.message;
                        }
                        if (mesh.failed)
                        {
                            return;
                        }
                        var now:int = getTimer();
                        if (now - began > slowestFeatureMs)
                        {
                            slowestFeatureMs = now - began;
                            slowestFeature = kind + " " + b.layer.id + " #" + index;
                        }
                        if (now >= deadline)
                        {
                            return;
                        }
                    }
                    mesh.itemIndex++;
                    mesh.featureIndex = 0;
                }
                flushChunk(mesh);
            }
            catch (error:Error)
            {
                errors++;
                lastError = "build: " + error.message;
                failMesh(mesh);
                return;
            }
            if (!mesh.failed)
            {
                mesh.ready = true;
                mesh.items = null;
            }
            m_building = null;
        }

        private function failMesh(mesh:GpuMesh):void
        {
            // keep what it is: an empty mesh retried later (the tile shows its CPU part meanwhile)
            for each (var chunk:GpuChunk in mesh.chunks)
            {
                try
                {
                    chunk.vertices.dispose();
                    chunk.indices.dispose();
                }
                catch (error:Error)
                {
                }
                m_bytes -= chunk.bytes;
                m_buffers -= 2;
            }
            mesh.chunks = [];
            mesh.itemIndex = 0;
            mesh.featureIndex = 0;
            mesh.failed = true;
            mesh.failedAt = m_now;
            if (m_building == mesh)
            {
                m_building = null;
            }
        }

        /** Uploads the current chunk of the mesh being built (group > 0: stencil filled fans). */
        private function flushChunk(mesh:GpuMesh, group:int = 0):void
        {
            var count:int = m_count;
            var indices:int = m_in;
            m_vn = 0;
            m_in = 0;
            m_count = 0;
            if (count == 0 || indices == 0)
            {
                return;
            }
            var bytes:Number = count * BYTES_PER_VERTEX + indices * 2;
            makeRoom(bytes, false);
            var chunk:GpuChunk = null;
            for (var attempt:int = 0; attempt < 2 && chunk == null; attempt++)
            {
                var vb:VertexBuffer3D = null;
                var ib:IndexBuffer3D = null;
                try
                {
                    vb = m_context.createVertexBuffer(count, FLOATS);
                    vb.uploadFromVector(m_v, 0, count);
                    ib = m_context.createIndexBuffer(indices);
                    ib.uploadFromVector(m_i, 0, indices);
                    chunk = new GpuChunk();
                    chunk.vertices = vb;
                    chunk.indices = ib;
                    chunk.triangles = indices / 3;
                    chunk.bytes = bytes;
                    chunk.group = group;
                }
                catch (error:Error)
                {
                    errors++;
                    lastError = "upload " + count + " vertices, " + indices + " indices: " + error.message;
                    // resource limit of the driver: free what is not on screen and try once more
                    try
                    {
                        if (vb != null) vb.dispose();
                        if (ib != null) ib.dispose();
                    }
                    catch (disposeError:Error)
                    {
                    }
                    makeRoom(bytes, true);
                }
            }
            if (chunk == null)
            {
                failMesh(mesh);
                return;
            }
            mesh.chunks.push(chunk);
            m_bytes += bytes;
            m_buffers += 2;
        }

        private function addFill(mesh:GpuMesh, b:LayerBucket, index:int, feature:MvtFeature):void
        {
            var rgb:uint;
            var alpha:Number;
            var opacity:Number = b.perFeature ? b.fillOpacities[index] : b.fillOpacity;
            var pattern:String = b.perFeature ? b.patternNames[index] : b.patternName;
            if (pattern != null)
            {
                // patterns are not textured yet: their average color
                var average:Object = patternColor(pattern);
                if (average == null)
                {
                    return;
                }
                rgb = average.rgb;
                alpha = average.a * opacity * b.groupAlpha;
            }
            else
            {
                var color:StyleColor = b.perFeature ? b.fillColors[index] : b.fillColor;
                if (color == null)
                {
                    return;
                }
                rgb = color.rgb;
                alpha = color.a * opacity * b.groupAlpha;
            }
            if (alpha <= 0)
            {
                return; // e.g. outline-only layers
            }
            if (alpha > 1)
            {
                alpha = 1;
            }
            var r:Number = ((rgb >> 16) & 255) / 255;
            var g:Number = ((rgb >> 8) & 255) / 255;
            var bl:Number = (rgb & 255) / 255;
            var polys:Array = polygonsOf(feature);
            var f:Number = 4096 / feature.extent; // layers of a tile may have different extents
            var v:Vector.<Number> = m_v;
            var idx:Vector.<uint> = m_i;
            for (var p:int = 0; p < polys.length; p++)
            {
                var poly:Object = polys[p];
                var n:int = poly.n;
                if (poly.fan)
                {
                    addFan(mesh, poly.rings, f, r, g, bl, alpha);
                    if (mesh.failed)
                    {
                        return;
                    }
                    v = m_v;
                    idx = m_i;
                    continue;
                }
                var tris:Vector.<int> = poly.tris;
                var numTris:int = tris.length;
                if (numTris == 0 || n > MAX_VERTICES)
                {
                    continue;
                }
                if (m_count + n > MAX_VERTICES)
                {
                    flushChunk(mesh);
                    if (mesh.failed)
                    {
                        return;
                    }
                }
                var base:int = m_count;
                var vn:int = m_vn;
                var rings:Array = poly.rings;
                for (var q:int = 0; q < rings.length; q++)
                {
                    var ring:Vector.<Number> = rings[q];
                    var len:int = ring.length;
                    for (var j:int = 0; j < len; j += 2)
                    {
                        v[vn++] = ring[j] * f;
                        v[vn++] = ring[int(j + 1)] * f;
                        v[vn++] = 0;
                        v[vn++] = 0;
                        v[vn++] = 0;
                        v[vn++] = 0;
                        v[vn++] = SOLID_PERIOD;
                        v[vn++] = 2;
                        v[vn++] = r;
                        v[vn++] = g;
                        v[vn++] = bl;
                        v[vn++] = alpha;
                    }
                }
                m_vn = vn;
                var ni:int = m_in;
                for (var t:int = 0; t < numTris; t++)
                {
                    idx[ni++] = base + tris[t];
                }
                m_in = ni;
                m_count += n;
            }
        }

        /**
         * Appends rings as triangle fans in chunks of their own, marked with a stencil group: the renderer
         * fills them with the even-odd rule (holes and nested rings come out right without triangulation).
         */
        private function addFan(mesh:GpuMesh, rings:Array, f:Number, r:Number, g:Number, b:Number, a:Number):void
        {
            flushChunk(mesh);
            if (mesh.failed)
            {
                return;
            }
            var group:int = ++s_groups;
            var v:Vector.<Number> = m_v;
            var idx:Vector.<uint> = m_i;
            for (var q:int = 0; q < rings.length; q++)
            {
                var ring:Vector.<Number> = rings[q];
                var len:int = ring.length;
                var n:int = len >> 1;
                if (m_count + n > MAX_VERTICES)
                {
                    flushChunk(mesh, group);
                    if (mesh.failed)
                    {
                        return;
                    }
                }
                var base:int = m_count;
                var vn:int = m_vn;
                for (var j:int = 0; j < len; j += 2)
                {
                    v[vn++] = ring[j] * f;
                    v[vn++] = ring[int(j + 1)] * f;
                    v[vn++] = 0;
                    v[vn++] = 0;
                    v[vn++] = 0;
                    v[vn++] = 0;
                    v[vn++] = SOLID_PERIOD;
                    v[vn++] = 2;
                    v[vn++] = r;
                    v[vn++] = g;
                    v[vn++] = b;
                    v[vn++] = a;
                }
                m_vn = vn;
                var ni:int = m_in;
                for (var k:int = 1; k < n - 1; k++)
                {
                    idx[ni++] = base;
                    idx[ni++] = base + k;
                    idx[ni++] = base + k + 1;
                }
                m_in = ni;
                m_count += n;
            }
            flushChunk(mesh, group);
        }

        /**
         * The polygons of a feature, prepared once and kept with the feature: {rings, tris, n, fan}.
         *
         * Big features (thousands of vertices or many rings, e.g. the forests of a whole region in one
         * multipolygon) are not triangulated: ear clipping costs holes x vertices and takes seconds on them.
         * They are returned as one "fan" entry with all their rings, filled by the GPU with the even-odd
         * rule through the stencil buffer (see addFill and render).
         *
         * The others are triangulated. Rings with the winding of the first one are exterior rings, the
         * others are holes: a hole belongs to the exterior ring before it (vector tile specification) when
         * its bounding box fits, otherwise to the smallest exterior ring that contains it.
         */
        private static function polygonsOf(feature:MvtFeature):Array
        {
            var polys:Array = feature.gpu as Array;
            if (polys != null)
            {
                return polys;
            }
            polys = [];
            feature.gpu = polys;
            var rings:Array = feature.loadGeometry();
            var q:int;
            var ring:Vector.<Number>;
            var total:int = 0;
            for (q = 0; q < rings.length; q++)
            {
                total += rings[q].length >> 1;
            }
            if (total > fanVertices || rings.length > fanRings)
            {
                var fanRings:Array = [];
                total = 0;
                for (q = 0; q < rings.length; q++)
                {
                    ring = rings[q];
                    if (ring.length >= 6 && ring.length >> 1 <= MAX_VERTICES)
                    {
                        fanRings.push(ring);
                        total += ring.length >> 1;
                    }
                }
                polys.push({rings: fanRings, tris: null, n: total, fan: true});
                return polys;
            }
            var holes:Array = null;
            var outerSign:int = 0;
            var poly:Object;
            var i:int;
            for (q = 0; q < rings.length; q++)
            {
                ring = rings[q];
                var n:int = ring.length;
                if (n < 6)
                {
                    continue;
                }
                var area:Number = 0;
                var minX:Number = ring[0];
                var maxX:Number = minX;
                var minY:Number = ring[1];
                var maxY:Number = minY;
                for (i = 0; i < n; i += 2)
                {
                    var x:Number = ring[i];
                    var y:Number = ring[int(i + 1)];
                    var j:int = i == 0 ? n - 2 : i - 2;
                    area += (ring[j] - x) * (y + ring[int(j + 1)]);
                    if (x < minX) minX = x; else if (x > maxX) maxX = x;
                    if (y < minY) minY = y; else if (y > maxY) maxY = y;
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
                var info:Object = {rings: [ring], tris: null, n: n >> 1, fan: false, minX: minX, minY: minY,
                                   maxX: maxX, maxY: maxY, area: area < 0 ? -area : area, before: polys.length - 1};
                if (s == outerSign)
                {
                    polys.push(info);
                }
                else
                {
                    if (holes == null)
                    {
                        holes = [];
                    }
                    holes.push(info);
                }
            }
            for each (var hole:Object in holes)
            {
                var owner:Object = hole.before >= 0 ? polys[hole.before] : null;
                if (owner == null || hole.minX < owner.minX || hole.maxX > owner.maxX || hole.minY < owner.minY ||
                    hole.maxY > owner.maxY || hole.area > owner.area)
                {
                    // not where the specification puts it: look for the ring that contains it
                    owner = null;
                    for each (poly in polys)
                    {
                        if ((owner == null || poly.area < owner.area) && contains(poly, hole))
                        {
                            owner = poly;
                        }
                    }
                }
                if (owner != null)
                {
                    owner.rings.push(hole.rings[0]);
                    owner.n += hole.n;
                }
            }
            for each (poly in polys)
            {
                var data:Vector.<Number> = poly.rings[0];
                var holeIndices:Vector.<int> = null;
                var count:int = poly.rings.length;
                if (count > 1)
                {
                    data = new Vector.<Number>(poly.n * 2, true);
                    holeIndices = new Vector.<int>();
                    var at:int = 0;
                    for (var h:int = 0; h < count; h++)
                    {
                        ring = poly.rings[h];
                        if (h > 0)
                        {
                            holeIndices.push(at >> 1);
                        }
                        var len:int = ring.length;
                        for (i = 0; i < len; i++)
                        {
                            data[at++] = ring[i];
                        }
                    }
                }
                try
                {
                    poly.tris = Earcut.triangulate(data, holeIndices);
                    if (Earcut.lastIncomplete && holeIndices != null)
                    {
                        // degenerate holes (touching each other or the border): even-odd fill instead
                        poly.tris = null;
                        poly.fan = true;
                    }
                }
                catch (error:Error)
                {
                    poly.tris = new Vector.<int>();
                }
            }
            return polys;
        }

        /** The hole lies inside the exterior ring of the polygon (bounding box, then some of its vertices). */
        private static function contains(poly:Object, hole:Object):Boolean
        {
            if (hole.minX < poly.minX || hole.maxX > poly.maxX || hole.minY < poly.minY || hole.maxY > poly.maxY ||
                hole.area > poly.area)
            {
                return false;
            }
            var outer:Vector.<Number> = poly.rings[0];
            var ring:Vector.<Number> = hole.rings[0];
            var n:int = outer.length;
            // vertices on the boundary are ambiguous: most of three must be inside
            var step:int = 2 * Math.max(1, int(ring.length / 6));
            var inside:int = 0;
            var tested:int = 0;
            for (var v:int = 0; v < ring.length && tested < 3; v += step)
            {
                var px:Number = ring[v];
                var py:Number = ring[int(v + 1)];
                var c:Boolean = false;
                for (var i:int = 0, j:int = n - 2; i < n; j = i, i += 2)
                {
                    var yi:Number = outer[int(i + 1)];
                    var yj:Number = outer[int(j + 1)];
                    if ((yi > py) != (yj > py) && px < (outer[j] - outer[i]) * (py - yi) / (yj - yi) + outer[i])
                    {
                        c = !c;
                    }
                }
                if (c)
                {
                    inside++;
                }
                tested++;
            }
            return inside * 2 > tested;
        }

        /** Lines of a line bucket, or the outline of a fill bucket (fill-outline-color / antialiasing hairline). */
        private function addLines(mesh:GpuMesh, b:LayerBucket, index:int, feature:MvtFeature, outline:Boolean,
                                  miterLimit:Number, caps:Boolean):void
        {
            var rgb:uint;
            var alpha:Number;
            var width:Number;
            var period:Number = SOLID_PERIOD;
            var on:Number = 1;
            if (outline)
            {
                var color:StyleColor = b.perFeature ? b.outlineColors[index] : b.outlineColor;
                var fillOpacity:Number = b.perFeature ? b.fillOpacities[index] : b.fillOpacity;
                if (color == null || color.a <= 0)
                {
                    // no outline color: like the CPU, an opaque fill gets a hairline of its own color
                    // (here it gives antialiased polygon edges)
                    color = b.perFeature ? b.fillColors[index] : b.fillColor;
                    var pattern:String = b.perFeature ? b.patternNames[index] : b.patternName;
                    if (!b.antialias || pattern != null || color == null || color.a * fillOpacity < 1)
                    {
                        return;
                    }
                }
                rgb = color.rgb;
                alpha = color.a * fillOpacity * b.groupAlpha;
                width = 1;
            }
            else
            {
                rgb = b.perFeature ? b.lineRgbs[index] : b.lineRgb;
                alpha = (b.perFeature ? b.lineAlphas[index] : b.lineAlpha) * b.groupAlpha;
                width = b.perFeature ? b.lineWidths[index] : b.lineWidth;
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
                return;
            }
            if (alpha > 1)
            {
                alpha = 1;
            }
            // half width plus the antialiasing margin; thinner lines fade through the coverage
            var e:Number = (width > 0.25 ? width : 0.25) / 2 + 0.5;
            var r:Number = ((rgb >> 16) & 255) / 255;
            var g:Number = ((rgb >> 8) & 255) / 255;
            var bl:Number = (rgb & 255) / 255;
            var parts:Array = feature.loadGeometry();
            var f:Number = 4096 / feature.extent; // layers of a tile may have different extents
            var xs:Vector.<Number> = m_xs;
            var ys:Vector.<Number> = m_ys;
            for (var p:int = 0; p < parts.length; p++)
            {
                // drop repeated points
                var part:Vector.<Number> = parts[p];
                var len:int = part.length;
                var n:int = 0;
                var px:Number = 0;
                var py:Number = 0;
                for (var i:int = 0; i + 1 < len; i += 2)
                {
                    var x:Number = part[i] * f;
                    var y:Number = part[int(i + 1)] * f;
                    if (n == 0 || x != px || y != py)
                    {
                        xs[n] = x;
                        ys[n] = y;
                        n++;
                        px = x;
                        py = y;
                    }
                }
                // very long lines are split (the pieces share their end point)
                var start:int = 0;
                while (start < n - 1)
                {
                    var end:int = start + STRIP_POINTS < n - 1 ? start + STRIP_POINTS : n - 1;
                    addStrip(mesh, start, end, e, period, on, r, g, bl, alpha, miterLimit, caps);
                    if (mesh.failed)
                    {
                        return;
                    }
                    start = end;
                }
            }
        }

        /**
         * Appends the points start..end of m_xs/m_ys as a triangle strip: two vertices per point, extruded
         * on both sides by the shader. Joins: miter up to miterLimit, otherwise bevel; caps: extended by
         * half the width when the style asks for round or square caps (round is approximated).
         */
        private function addStrip(mesh:GpuMesh, start:int, end:int, e:Number, period:Number, on:Number,
                                  r:Number, g:Number, b:Number, a:Number, miterLimit:Number, caps:Boolean):void
        {
            if (m_count + 4 * (end - start + 1) > MAX_VERTICES)
            {
                flushChunk(mesh);
                if (mesh.failed)
                {
                    return;
                }
            }
            var xs:Vector.<Number> = m_xs;
            var ys:Vector.<Number> = m_ys;
            var distance:Number = 0;
            var inX:Number = 0;
            var inY:Number = 0;
            var outX:Number = 0;
            var outY:Number = 0;
            var length:Number;
            m_previous = -1;
            for (var i:int = start; i <= end; i++)
            {
                var x:Number = xs[i];
                var y:Number = ys[i];
                if (i > start)
                {
                    inX = x - xs[int(i - 1)];
                    inY = y - ys[int(i - 1)];
                    length = Math.sqrt(inX * inX + inY * inY);
                    distance += length;
                    inX /= length;
                    inY /= length;
                }
                if (i < end)
                {
                    outX = xs[int(i + 1)] - x;
                    outY = ys[int(i + 1)] - y;
                    length = Math.sqrt(outX * outX + outY * outY);
                    outX /= length;
                    outY /= length;
                }
                if (i == start)
                {
                    // start: normal of the first segment, optional cap backwards
                    pair(x, y, -outY, outX, caps ? -outX : 0, caps ? -outY : 0, e, distance, period, on, r, g, b, a);
                }
                else if (i == end)
                {
                    pair(x, y, -inY, inX, caps ? inX : 0, caps ? inY : 0, e, distance, period, on, r, g, b, a);
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
                        pair(x, y, mx * scale, my * scale, 0, 0, e, distance, period, on, r, g, b, a);
                    }
                    else
                    {
                        // bevel: end the incoming segment and start the outgoing one at the same point
                        pair(x, y, -inY, inX, 0, 0, e, distance, period, on, r, g, b, a);
                        pair(x, y, -outY, outX, 0, 0, e, distance, period, on, r, g, b, a);
                    }
                }
            }
        }

        /** Appends the left and right vertices of a point (normal nx, ny; tangent offset tx, ty for caps). */
        private function pair(x:Number, y:Number, nx:Number, ny:Number, tx:Number, ty:Number, e:Number,
                              distance:Number, period:Number, on:Number, r:Number, g:Number, b:Number, a:Number):void
        {
            var v:Vector.<Number> = m_v;
            var n:int = m_vn;
            v[n++] = x; v[n++] = y; v[n++] = nx + tx; v[n++] = ny + ty;
            v[n++] = e; v[n++] = distance; v[n++] = period; v[n++] = on;
            v[n++] = r; v[n++] = g; v[n++] = b; v[n++] = a;
            v[n++] = x; v[n++] = y; v[n++] = tx - nx; v[n++] = ty - ny;
            v[n++] = -e; v[n++] = distance; v[n++] = period; v[n++] = on;
            v[n++] = r; v[n++] = g; v[n++] = b; v[n++] = a;
            m_vn = n;
            var left:int = m_count;
            var previous:int = m_previous;
            if (previous >= 0)
            {
                var idx:Vector.<uint> = m_i;
                var k:int = m_in;
                idx[k++] = previous; idx[k++] = previous + 1; idx[k++] = left;
                idx[k++] = previous + 1; idx[k++] = left + 1; idx[k++] = left;
                m_in = k;
            }
            m_previous = left;
            m_count += 2;
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
    }
}

import flash.display3D.IndexBuffer3D;
import flash.display3D.VertexBuffer3D;

/** Buffers of up to 65535 vertices. */
final class GpuChunk
{
    public var vertices:VertexBuffer3D;
    public var indices:IndexBuffer3D;
    public var triangles:int;
    public var bytes:Number;
    /** 0, or the id of the even-odd (stencil) fill the chunk belongs to. */
    public var group:int = 0;
}

/** Fills, lines and outlines of a data tile at a zoom, in style order. */
final class GpuMesh
{
    public var id:int;
    public var generation:int;
    public var chunks:Array = [];
    /** Meshes are in units of 1/4096 of the tile, whatever the extent of each layer. */
    public var extent:Number = 4096;
    public var ready:Boolean = false;
    public var disposed:Boolean = false;
    public var failed:Boolean = false;
    public var failedAt:int;
    /** getTimer of the last use; frame of the last use. */
    public var used:int;
    public var frame:int;
    // build state
    public var items:Array;
    public var itemIndex:int = 0;
    public var featureIndex:int = 0;
    // draw record of the current frame
    public var recordFrame:int = -1;
    public var k:Number;
    public var scale:Number;
    public var sx:Number;
    public var sy:Number;
    public var tx:Number;
    public var ty:Number;
    public var left:Number;
    public var top:Number;
    public var right:Number;
    public var bottom:Number;
    public var clearUnder:Boolean;
}
