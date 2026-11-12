package org.falpi.ags.layers
{
    import com.esri.ags.events.ZoomEvent;
    import com.esri.ags.geometry.Extent;
    import com.esri.ags.layers.WebTiledLayer;

    import flash.display.DisplayObject;
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
    import flash.geom.Matrix;
    import flash.geom.Point;
    import flash.geom.Rectangle;
    import flash.text.TextField;
    import flash.text.TextFieldAutoSize;
    import flash.text.TextFormat;
    import flash.utils.ByteArray;
    import flash.utils.Endian;
    import flash.utils.getQualifiedClassName;
    import flash.utils.getTimer;

    import mx.core.UIComponent;

    /**
     * Phase 0 probe (Stage3D feasibility), not part of the public API.
     *
     * A WebTiledLayer (OpenStreetMap raster by default) drawn at 50% opacity; underneath, on Stage3D,
     * the same tile grid, a polygon over Rome and a frame along the map border. During pan and zoom
     * the GPU grid must stay aligned with the raster tile edges. A status box at the top left of the map
     * shows the Stage3D driver, the frame rate and errors. The page must use wmode="direct" and the
     * application/map backgrounds must be transparent where the map is.
     */
    public class Stage3DProbeLayer extends WebTiledLayer
    {
        private static const ORIGIN:Number = 20037508.342789244;

        private var m_stage3D:Stage3D;
        private var m_context:Context3D;
        private var m_program:Program3D;
        private var m_vertices:VertexBuffer3D;
        private var m_indices:IndexBuffer3D;
        private var m_bufferWidth:int;
        private var m_bufferHeight:int;
        private var m_status:TextField;
        private var m_error:String;

        // map -> layer pixels at the last updateLayer, then the zoom animation on top of it
        private var m_hasBase:Boolean;
        private var m_baseX:Number;
        private var m_baseY:Number;
        private var m_baseViewX:Number;
        private var m_baseViewY:Number;
        private var m_baseResolution:Number;
        private var m_zoomMatrix:Matrix = new Matrix();

        private var m_frames:int;
        private var m_fpsTime:int;
        private var m_fps:Number = 0;

        public function Stage3DProbeLayer(urlTemplate:String = "https://tile.openstreetmap.org/{level}/{col}/{row}.png")
        {
            super(urlTemplate);
            alpha = 0.5;
            addEventListener(Event.ADDED_TO_STAGE, addedToStage);
            addEventListener(Event.REMOVED_FROM_STAGE, removedFromStage);
        }

        // ------------------------------------------------------------------
        // map synchronisation
        // ------------------------------------------------------------------

        override protected function updateLayer():void
        {
            super.updateLayer();
            var extent:Extent = map != null ? map.extent : null;
            if (extent == null || extent.width <= 0)
            {
                m_hasBase = false;
                return;
            }
            var x0:Number = toScreenX(extent.xmin);
            var x1:Number = toScreenX(extent.xmax);
            var y0:Number = toScreenY(extent.ymax);
            if (isNaN(x0) || isNaN(x1) || x1 <= x0)
            {
                m_hasBase = false;
                return;
            }
            m_baseX = extent.xmin;
            m_baseY = extent.ymax;
            m_baseViewX = x0;
            m_baseViewY = y0;
            m_baseResolution = extent.width / (x1 - x0);
            m_zoomMatrix.identity();
            m_hasBase = true;
        }

        override protected function zoomUpdateHandler(event:ZoomEvent):void
        {
            super.zoomUpdateHandler(event);
            var viewport:Object = internalValue(map, "viewport");
            var scrollRect:Rectangle = viewport != null ? viewport.scrollRect as Rectangle : null;
            var width:Number = Number(internalValue(event, "width"));
            var x:Number = Number(internalValue(event, "x"));
            var y:Number = Number(internalValue(event, "y"));
            if (scrollRect == null || scrollRect.width <= 0 || isNaN(width) || isNaN(x) || isNaN(y))
            {
                return;
            }
            var ratio:Number = width / scrollRect.width;
            m_zoomMatrix.identity();
            m_zoomMatrix.scale(ratio, ratio);
            m_zoomMatrix.translate(x + scrollRect.x - scrollRect.x * ratio, y + scrollRect.y - scrollRect.y * ratio);
        }

        private static function internalValue(target:Object, name:String):*
        {
            try
            {
                return target[new QName(new Namespace("http://www.esri.com/2008/ags/internal"), name)];
            }
            catch (error:Error)
            {
            }
            return undefined;
        }

        /** Map coordinates -> stage pixels, through the layer (pan is the viewport scrollRect). */
        private function mapToStage(mx:Number, my:Number):Point
        {
            var p:Point = new Point(m_baseViewX + (mx - m_baseX) / m_baseResolution,
                                    m_baseViewY + (m_baseY - my) / m_baseResolution);
            return localToGlobal(m_zoomMatrix.transformPoint(p));
        }

        // ------------------------------------------------------------------
        // Stage3D
        // ------------------------------------------------------------------

        private function addedToStage(event:Event):void
        {
            m_status = new TextField();
            m_status.autoSize = TextFieldAutoSize.LEFT;
            m_status.background = true;
            m_status.backgroundColor = 0xFFFFE0;
            m_status.border = true;
            m_status.defaultTextFormat = new TextFormat("_sans", 11, 0x000000);
            m_status.mouseEnabled = false;
            stage.addChild(m_status);
            status("requesting Context3D...");
            if (stage.stage3Ds == null || stage.stage3Ds.length == 0)
            {
                status("no Stage3D available");
                return;
            }
            m_stage3D = stage.stage3Ds[0];
            m_stage3D.addEventListener(Event.CONTEXT3D_CREATE, contextCreated);
            m_stage3D.addEventListener(ErrorEvent.ERROR, contextError);
            try
            {
                m_stage3D.requestContext3D();
            }
            catch (error:Error)
            {
                m_error = "requestContext3D: " + error.message;
            }
            addEventListener(Event.ENTER_FRAME, frame);
            m_fpsTime = getTimer();
        }

        private function removedFromStage(event:Event):void
        {
            removeEventListener(Event.ENTER_FRAME, frame);
            if (m_status != null && m_status.parent != null)
            {
                m_status.parent.removeChild(m_status);
            }
            if (m_stage3D != null)
            {
                m_stage3D.visible = false;
                m_stage3D.removeEventListener(Event.CONTEXT3D_CREATE, contextCreated);
                m_stage3D.removeEventListener(ErrorEvent.ERROR, contextError);
            }
            if (m_context != null)
            {
                m_context.dispose();
            }
            m_context = null;
            m_stage3D = null;
        }

        private function contextError(event:ErrorEvent):void
        {
            m_error = "Context3D error: " + event.text;
        }

        private function contextCreated(event:Event):void
        {
            // also called again after a context loss: everything is recreated
            m_context = m_stage3D.context3D;
            m_bufferWidth = 0;
            m_bufferHeight = 0;
            m_vertices = null;
            m_indices = null;
            try
            {
                m_context.enableErrorChecking = true;
                m_program = m_context.createProgram();
                m_program.upload(movProgram(false, 0, 0), movProgram(true, 1, 0));
                m_context.setBlendFactors(Context3DBlendFactor.SOURCE_ALPHA, Context3DBlendFactor.ONE_MINUS_SOURCE_ALPHA);
            }
            catch (error:Error)
            {
                m_error = "setup: " + error.message;
                m_context = null;
            }
        }

        /** AGAL: "mov op, va0" (vertex) or "mov oc, fc0" (fragment). */
        private static function movProgram(fragment:Boolean, sourceType:int, sourceRegister:int):ByteArray
        {
            var b:ByteArray = new ByteArray();
            b.endian = Endian.LITTLE_ENDIAN;
            b.writeByte(0xA0);
            b.writeUnsignedInt(1);          // AGAL version
            b.writeByte(0xA1);
            b.writeByte(fragment ? 1 : 0);  // shader type
            b.writeUnsignedInt(0x00);       // opcode mov
            b.writeShort(0);                // destination: register 0
            b.writeByte(0x0F);              // write mask xyzw
            b.writeByte(3);                 // output register
            b.writeShort(sourceRegister);   // source 1
            b.writeByte(0);                 // indirect offset
            b.writeByte(0xE4);              // swizzle xyzw
            b.writeByte(sourceType);        // 0 attribute, 1 constant
            b.writeByte(0);
            b.writeShort(0);
            for (var i:int = 0; i < 8; i++) // source 2 unused
            {
                b.writeByte(0);
            }
            return b;
        }

        private function frame(event:Event):void
        {
            m_frames++;
            var now:int = getTimer();
            if (now - m_fpsTime >= 1000)
            {
                m_fps = m_frames * 1000 / (now - m_fpsTime);
                m_frames = 0;
                m_fpsTime = now;
            }
            if (map == null || m_stage3D == null)
            {
                return;
            }
            var topLeft:Point = map.localToGlobal(new Point(0, 0));
            var bottomRight:Point = map.localToGlobal(new Point(map.width, map.height));
            var width:int = Math.round(bottomRight.x - topLeft.x);
            var height:int = Math.round(bottomRight.y - topLeft.y);
            m_status.x = topLeft.x + 8;
            m_status.y = topLeft.y + 8;
            if (m_context == null || m_context.driverInfo == "Disposed")
            {
                status(m_error != null ? m_error : "waiting for Context3D...");
                return;
            }
            if (now - m_coverTime > 2000)
            {
                m_coverTime = now;
                m_cover = coverReport(new Point(topLeft.x + width / 2, topLeft.y + height / 2));
            }
            status("Stage3D " + m_context.driverInfo + " | " + width + "x" + height + " | " + m_fps.toFixed(0) + " fps" +
                   (m_error != null ? "\n" + m_error : "") + (m_cover != null ? "\n" + m_cover : ""));
            // Stage3D is not part of the display list: hide it ourselves when the layer is not on screen
            // (basemap switched off, map in another tab...), otherwise the last frame stays under the UI
            var onScreen:Boolean = width >= 50 && height >= 50 && isOnScreen();
            m_stage3D.visible = onScreen;
            m_status.visible = onScreen;
            if (!onScreen)
            {
                return;
            }
            try
            {
                m_stage3D.x = topLeft.x;
                m_stage3D.y = topLeft.y;
                if (width != m_bufferWidth || height != m_bufferHeight)
                {
                    m_context.configureBackBuffer(width, height, 2, false);
                    m_bufferWidth = width;
                    m_bufferHeight = height;
                }
                draw(topLeft, width, height);
            }
            catch (error:Error)
            {
                m_error = "draw: " + error.message;
            }
        }

        // ------------------------------------------------------------------
        // drawing
        // ------------------------------------------------------------------

        private var m_v:Vector.<Number>;
        private var m_i:Vector.<uint>;
        private var m_draws:Array;
        private var m_origin:Point;
        private var m_width:Number;
        private var m_height:Number;

        private function draw(topLeft:Point, width:int, height:int):void
        {
            m_context.clear(0.85, 0.92, 1, 1);
            m_v = new Vector.<Number>();
            m_i = new Vector.<uint>();
            m_draws = [];
            m_origin = topLeft;
            m_width = width;
            m_height = height;

            // frame along the border of the map: checks position and size of the Stage3D rectangle
            begin(0x00A000, 1);
            quadScreen(topLeft.x, topLeft.y, topLeft.x + width, topLeft.y + 4);
            quadScreen(topLeft.x, topLeft.y + height - 4, topLeft.x + width, topLeft.y + height);
            quadScreen(topLeft.x, topLeft.y, topLeft.x + 4, topLeft.y + height);
            quadScreen(topLeft.x + width - 4, topLeft.y, topLeft.x + width, topLeft.y + height);

            if (m_hasBase)
            {
                // polygon over Rome (Web Mercator)
                begin(0xE03020, 0.6);
                var cx:Number = 1389000;
                var cy:Number = 5146000;
                var r:Number = 6000;
                var first:int = m_v.length / 4;
                var c:Point = mapToStage(cx, cy);
                vertex(c.x, c.y);
                for (var a:int = 0; a <= 6; a++)
                {
                    var p:Point = mapToStage(cx + r * Math.cos(a * Math.PI / 3), cy + r * Math.sin(a * Math.PI / 3));
                    vertex(p.x, p.y);
                    if (a > 0)
                    {
                        triangle(first, first + a, first + a + 1);
                    }
                }

                // tile grid of the current level
                begin(0x0040C0, 0.9);
                var level:int = Math.max(0, Math.round(map.level));
                var span:Number = ORIGIN * 2 / Math.pow(2, level);
                var tl:Point = stageToMap(topLeft.x, topLeft.y);
                var br:Point = stageToMap(topLeft.x + width, topLeft.y + height);
                var c0:int = Math.floor((tl.x + ORIGIN) / span);
                var c1:int = Math.ceil((br.x + ORIGIN) / span);
                var r0:int = Math.floor((ORIGIN - tl.y) / span);
                var r1:int = Math.ceil((ORIGIN - br.y) / span);
                if (c1 - c0 < 200 && r1 - r0 < 200)
                {
                    for (var col:int = c0; col <= c1; col++)
                    {
                        var sx:Number = mapToStage(-ORIGIN + col * span, 0).x;
                        quadScreen(sx - 1, topLeft.y, sx + 1, topLeft.y + height);
                    }
                    for (var row:int = r0; row <= r1; row++)
                    {
                        var sy:Number = mapToStage(0, ORIGIN - row * span).y;
                        quadScreen(topLeft.x, sy - 1, topLeft.x + width, sy + 1);
                    }
                }
            }
            end();

            if (m_vertices != null)
            {
                m_vertices.dispose();
            }
            if (m_indices != null)
            {
                m_indices.dispose();
            }
            m_vertices = m_context.createVertexBuffer(m_v.length / 4, 4);
            m_vertices.uploadFromVector(m_v, 0, m_v.length / 4);
            m_indices = m_context.createIndexBuffer(m_i.length);
            m_indices.uploadFromVector(m_i, 0, m_i.length);
            m_context.setProgram(m_program);
            m_context.setVertexBufferAt(0, m_vertices, 0, Context3DVertexBufferFormat.FLOAT_4);
            for each (var d:Object in m_draws)
            {
                if (d.count > 0)
                {
                    m_context.setProgramConstantsFromVector(Context3DProgramType.FRAGMENT, 0, d.color);
                    m_context.drawTriangles(m_indices, d.first, d.count / 3);
                }
            }
            m_context.present();
        }

        private function stageToMap(sx:Number, sy:Number):Point
        {
            var p0:Point = mapToStage(m_baseX, m_baseY);
            var p1:Point = mapToStage(m_baseX + m_baseResolution * 1000, m_baseY);
            var k:Number = (p1.x - p0.x) / (m_baseResolution * 1000); // stage pixels per map unit
            return new Point(m_baseX + (sx - p0.x) / k, m_baseY - (sy - p0.y) / k);
        }

        private var m_current:Object;

        private function begin(rgb:uint, alpha:Number):void
        {
            end();
            m_current = {first: m_i.length, count: 0,
                color: Vector.<Number>([(rgb >> 16 & 255) / 255, (rgb >> 8 & 255) / 255, (rgb & 255) / 255, alpha])};
        }

        private function end():void
        {
            if (m_current != null)
            {
                m_current.count = m_i.length - m_current.first;
                m_draws.push(m_current);
                m_current = null;
            }
        }

        /** Adds a vertex given in stage pixels (converted to clip space). */
        private function vertex(sx:Number, sy:Number):void
        {
            m_v.push((sx - m_origin.x) / m_width * 2 - 1, 1 - (sy - m_origin.y) / m_height * 2, 0, 1);
        }

        private function triangle(a:int, b:int, c:int):void
        {
            m_i.push(a, b, c);
        }

        private function quadScreen(x0:Number, y0:Number, x1:Number, y1:Number):void
        {
            var first:int = m_v.length / 4;
            vertex(x0, y0);
            vertex(x1, y0);
            vertex(x1, y1);
            vertex(x0, y1);
            triangle(first, first + 1, first + 2);
            triangle(first, first + 2, first + 3);
        }

        private var m_coverTime:int;
        private var m_cover:String;

        /**
         * Diagnostic: what in the display list covers Stage3D at the given stage point.
         * Hides the map, then its ancestors one by one (flash-level visibility, no Flex events, restored at once),
         * and reports the alpha of the display list at that point after each step: the first ancestor after
         * which the alpha drops to 0 is the outermost one that paints an opaque background under the map.
         */
        private function coverReport(p:Point):String
        {
            // everything drawn at the point outside the map (back to front): candidates for an opaque background.
            // getObjectsUnderPoint reads no pixels, so it needs no cross-domain policy
            var lines:Array = ["under the map (back to front):"];
            try
            {
                var objects:Array = stage.getObjectsUnderPoint(p);
                for each (var o:DisplayObject in objects)
                {
                    if (map.contains(o) || o == m_status || !onScreenChain(o))
                    {
                        continue;
                    }
                    lines.push("  " + describe(o) + (o.alpha < 1 ? " alpha=" + o.alpha.toFixed(2) : ""));
                }
                if (lines.length == 1)
                {
                    lines.push("  nothing");
                }
            }
            catch (error:Error)
            {
                lines.push("cover check: " + error.message);
            }
            return lines.join("\n");
        }

        private function onScreenChain(o:DisplayObject):Boolean
        {
            for (var d:DisplayObject = o; d != null && d != stage; d = d.parent)
            {
                if (!d.visible || d.alpha == 0)
                {
                    return false;
                }
            }
            return true;
        }

        private static function describe(o:DisplayObject):String
        {
            var s:String = getQualifiedClassName(o).replace(/^.*::/, "");
            if (!(o is UIComponent) && o.parent is UIComponent)
            {
                s += " in " + describe(o.parent); // a Shape/graphic of a component
                return s;
            }
            if ("hostComponent" in o && o["hostComponent"] is UIComponent)
            {
                s += " of " + describe(o["hostComponent"]); // skin: the styles are the host's
                return s;
            }
            if (o is UIComponent)
            {
                var c:UIComponent = UIComponent(o);
                if (c.id != null)
                {
                    s += "#" + c.id;
                }
                s += " bg=" + hex(c.getStyle("backgroundColor")) + "/" + c.getStyle("backgroundAlpha");
                var skin:Object = "skin" in c ? c["skin"] : null;
                if (skin != null)
                {
                    s += " skin=" + getQualifiedClassName(skin).replace(/^.*::/, "");
                }
            }
            return s;
        }

        private static function hex(v:*):String
        {
            return v === undefined || v === null ? "-" : "#" + uint(v).toString(16);
        }

        /** True when the layer and all its ancestors are visible. */
        private function isOnScreen():Boolean
        {
            for (var d:DisplayObject = this; d != null; d = d.parent)
            {
                if (!d.visible)
                {
                    return false;
                }
                if (d == stage)
                {
                    return true;
                }
            }
            return false;
        }

        private function status(text:String):void
        {
            if (m_status != null && m_status.text != text)
            {
                m_status.text = text;
            }
        }
    }
}
