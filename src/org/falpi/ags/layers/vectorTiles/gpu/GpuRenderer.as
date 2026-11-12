package org.falpi.ags.layers.vectorTiles.gpu
{
    import org.falpi.ags.layers.vectorTiles.mvt.MvtFeature;
    import org.falpi.ags.layers.vectorTiles.render.LayerBucket;
    import org.falpi.ags.layers.vectorTiles.render.SourceTile;
    import org.falpi.ags.layers.vectorTiles.style.StyleColor;

    import flash.display.BitmapData;
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
     * Coordinates: meshes keep the geometry in tile extent units; each draw maps them to clip space
     * with one constant register (scale, offset), so the same mesh serves every tile and every frame.
     */
    public final class GpuRenderer
    {
        private static const MAX_VERTICES:int = 65535;
        private static const MESH_TTL_FRAMES:int = 900;
        private static var s_owners:Dictionary = new Dictionary(true);
        /** Called (once) when a renderer releases its Stage3D: layers waiting to use it. */
        private static var s_waiting:Array = [];

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

        private static const FILL_VERTEX:String =
            "mov vt0, vc1\n" +                  // (0, 0, 0, 1)
            "mul vt0.xy, va0.xy, vc0.xy\n" +    // tile units -> clip space
            "add vt0.xy, vt0.xy, vc0.zw\n" +
            "mov op, vt0\n" +
            "mov v0, va1\n";                    // color
        private static const FILL_FRAGMENT:String =
            "mul ft0, v0, fc0\n" +              // fc0 = (1, 1, 1, layer alpha)
            "mov oc, ft0\n";

        private var m_stage:Stage;
        private var m_stage3D:Stage3D;
        private var m_context:Context3D;
        private var m_fillProgram:Program3D;
        private var m_generation:int = 0;
        private var m_onState:Function;

        private var m_bufferWidth:int;
        private var m_bufferHeight:int;
        private var m_view:Rectangle = new Rectangle();
        private var m_frame:int = 0;
        private var m_alpha:Number = 1;

        /** bucket -> mesh. */
        private var m_meshes:Dictionary = new Dictionary();

        /** True once a hardware context is ready. */
        public var available:Boolean = false;
        /** Set when the GPU cannot be used (no Stage3D, software only, error): the layer falls back to CPU. */
        public var failure:String;
        /** The failure is only that another layer is using the Stage3D (it may be released later). */
        public var busy:Boolean = false;
        /** Stage3D driver description (Context3D.driverInfo). */
        public var driverInfo:String;
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
                m_context.setBlendFactors(Context3DBlendFactor.SOURCE_ALPHA, Context3DBlendFactor.ONE_MINUS_SOURCE_ALPHA);
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
            m_alpha = alpha;
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
            m_context.setProgram(m_fillProgram);
            m_context.setProgramConstantsFromVector(Context3DProgramType.VERTEX, 1, Vector.<Number>([0, 0, 0, 1]));
            m_context.setProgramConstantsFromVector(Context3DProgramType.FRAGMENT, 0, Vector.<Number>([1, 1, 1, alpha]));
            return true;
        }

        /**
         * Draws a fill bucket of one display tile.
         * @param source data tile placement (overzoom scale and offset) of the display tile
         * @param size display tile size in tile pixels
         * @param stageX, stageY stage position of the tile pixel (0, 0)
         * @param stageScale stage pixels per tile pixel
         * @param clip stage rectangle of the display tile
         */
        public function drawFill(b:LayerBucket, source:SourceTile, size:Number, stageX:Number, stageY:Number,
                                 stageScale:Number, clip:Rectangle):void
        {
            var mesh:Object = fillMesh(b);
            if (mesh == null || mesh.chunks.length == 0)
            {
                return;
            }
            var scissor:Rectangle = clip.intersection(m_view);
            if (scissor.width < 1 || scissor.height < 1)
            {
                return;
            }
            scissor.offset(-m_view.x, -m_view.y);
            m_context.setScissorRectangle(new Rectangle(Math.floor(scissor.x), Math.floor(scissor.y),
                Math.ceil(scissor.width), Math.ceil(scissor.height)));

            // tile units -> tile pixels -> stage -> clip space
            var k:Number = size * source.scale / mesh.extent;
            var ox:Number = -source.offsetX * size + b.translateX;
            var oy:Number = -source.offsetY * size + b.translateY;
            var sx:Number = k * stageScale * 2 / m_view.width;
            var sy:Number = -k * stageScale * 2 / m_view.height;
            var tx:Number = (stageX + ox * stageScale - m_view.x) * 2 / m_view.width - 1;
            var ty:Number = 1 - (stageY + oy * stageScale - m_view.y) * 2 / m_view.height;
            m_context.setProgramConstantsFromVector(Context3DProgramType.VERTEX, 0, Vector.<Number>([sx, sy, tx, ty]));
            for each (var chunk:Object in mesh.chunks)
            {
                m_context.setVertexBufferAt(0, chunk.vertices, 0, Context3DVertexBufferFormat.FLOAT_2);
                m_context.setVertexBufferAt(1, chunk.vertices, 2, Context3DVertexBufferFormat.BYTES_4);
                m_context.drawTriangles(chunk.indices, 0, chunk.triangles);
            }
            mesh.frame = m_frame;
        }

        public function endFrame():void
        {
            m_context.setScissorRectangle(null);
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

        private function fillMesh(b:LayerBucket):Object
        {
            var mesh:Object = m_meshes[b];
            if (mesh != null && mesh.generation == m_generation)
            {
                return mesh;
            }
            mesh = {generation: m_generation, frame: m_frame, chunks: [], extent: 4096};
            m_meshes[b] = mesh;

            var vertices:ByteArray = newVertexBytes();
            var indices:Vector.<uint> = new Vector.<uint>();
            var count:int = 0;
            var features:Vector.<MvtFeature> = b.features;
            for (var i:int = 0; i < features.length; i++)
            {
                var feature:MvtFeature = features[i];
                mesh.extent = feature.extent;
                var color:StyleColor = b.perFeature ? b.fillColors[i] : b.fillColor;
                var opacity:Number = b.perFeature ? b.fillOpacities[i] : b.fillOpacity;
                var alpha:Number = color != null ? color.a * opacity * b.groupAlpha : 0;
                if (alpha <= 0)
                {
                    continue; // patterns and outlines are not drawn on the GPU yet
                }
                var r:int = (color.rgb >> 16) & 255;
                var g:int = (color.rgb >> 8) & 255;
                var bl:int = color.rgb & 255;
                var a:int = Math.round(Math.min(1, alpha) * 255);
                for each (var polygon:Object in polygons(feature.loadGeometry()))
                {
                    var data:Vector.<Number> = polygon.data;
                    var n:int = data.length >> 1;
                    if (n < 3)
                    {
                        continue;
                    }
                    var triangles:Vector.<int> = Earcut.triangulate(data, polygon.holes);
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
                        vertices.writeFloat(data[v * 2]);
                        vertices.writeFloat(data[v * 2 + 1]);
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
            addChunk(mesh, vertices, indices, count);
            return mesh;
        }

        /** Vertex layout: x, y (float, little endian), color r, g, b, a (bytes). */
        private static function newVertexBytes():ByteArray
        {
            var bytes:ByteArray = new ByteArray();
            bytes.endian = Endian.LITTLE_ENDIAN;
            return bytes;
        }

        private function addChunk(mesh:Object, vertices:ByteArray, indices:Vector.<uint>, count:int):void
        {
            if (count == 0 || indices.length == 0)
            {
                return;
            }
            var vb:VertexBuffer3D = m_context.createVertexBuffer(count, 3);
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
            for (var key:Object in m_meshes)
            {
                var mesh:Object = m_meshes[key];
                if (m_frame - mesh.frame > MESH_TTL_FRAMES || mesh.generation != m_generation)
                {
                    disposeMesh(mesh);
                    delete m_meshes[key];
                }
            }
        }

        private function disposeMeshes():void
        {
            for each (var mesh:Object in m_meshes)
            {
                disposeMesh(mesh);
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
