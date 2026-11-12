package org.falpi.ags.layers.vectorTiles.mvt
{
    import org.falpi.ags.layers.vectorTiles.pbf.PbfReader;

    import flash.utils.ByteArray;

    /** A feature of a vector tile layer. Geometry is decoded on demand and cached. */
    public final class MvtFeature
    {
        public static const UNKNOWN:uint = 0;
        public static const POINT:uint = 1;
        public static const LINESTRING:uint = 2;
        public static const POLYGON:uint = 3;

        public static const TYPE_NAMES:Array = ["Unknown", "Point", "LineString", "Polygon"];

        public var id:Number = NaN;
        public var type:uint = UNKNOWN;
        public var extent:uint;
        public var properties:Object = {};
        /** Bounding box of the geometry in tile extent units (valid after loadGeometry). */
        public var minX:Number = 0;
        public var minY:Number = 0;
        public var maxX:Number = 0;
        public var maxY:Number = 0;

        private var m_bytes:ByteArray;
        private var m_geometryStart:int = -1;
        private var m_geometryLength:uint;
        private var m_geometry:Array;

        public function MvtFeature(bytes:ByteArray, start:uint, length:uint, keys:Array, values:Array, extent:uint)
        {
            m_bytes = bytes;
            this.extent = extent;
            var pbf:PbfReader = new PbfReader(bytes, start, length);
            while (pbf.next())
            {
                switch (pbf.tag)
                {
                    case 1:
                        id = pbf.readVarint64();
                        break;
                    case 2:
                        var tagsEnd:uint = pbf.readVarint();
                        tagsEnd += pbf.pos;
                        while (pbf.pos < tagsEnd)
                        {
                            var key:String = keys[pbf.readVarint()];
                            properties[key] = values[pbf.readVarint()];
                        }
                        break;
                    case 3:
                        type = pbf.readVarint();
                        break;
                    case 4:
                        m_geometryStart = pbf.readRange();
                        m_geometryLength = pbf.lastLength;
                        break;
                    default:
                        pbf.skip();
                }
            }
        }

        public function get typeName():String
        {
            return TYPE_NAMES[type < 4 ? type : 0];
        }

        /**
         * Returns the geometry as an Array of parts. Each part is a
         * Vector.&lt;Number&gt; of interleaved x,y in tile extent units.
         * Points: one part per point. Lines: one part per line string.
         * Polygons: one part per ring (closed, first point repeated).
         */
        public function loadGeometry():Array
        {
            if (m_geometry != null)
            {
                return m_geometry;
            }
            var parts:Array = [];
            m_geometry = parts;
            if (m_geometryStart < 0)
            {
                return parts;
            }
            var pbf:PbfReader = new PbfReader(m_bytes, m_geometryStart, m_geometryLength);
            var end:uint = pbf.end;
            var cmd:uint = 1;
            var count:uint = 0;
            var x:int = 0;
            var y:int = 0;
            var part:Vector.<Number> = null;
            var n:uint = 0;
            var x0:int = int.MAX_VALUE;
            var y0:int = int.MAX_VALUE;
            var x1:int = int.MIN_VALUE;
            var y1:int = int.MIN_VALUE;
            while (pbf.pos < end)
            {
                if (count == 0)
                {
                    var cmdLen:uint = pbf.readVarint();
                    cmd = cmdLen & 7;
                    count = cmdLen >>> 3;
                    if (count == 0 && cmd != 7)
                    {
                        continue;
                    }
                }
                if (cmd == 1 || cmd == 2)
                {
                    count--;
                    x += pbf.readSVarint();
                    y += pbf.readSVarint();
                    if (cmd == 1)
                    {
                        part = new Vector.<Number>();
                        parts.push(part);
                        n = 0;
                    }
                    if (part != null)
                    {
                        part[n++] = x;
                        part[n++] = y;
                        if (x < x0) x0 = x;
                        if (x > x1) x1 = x;
                        if (y < y0) y0 = y;
                        if (y > y1) y1 = y;
                    }
                }
                else if (cmd == 7)
                {
                    if (count > 0)
                    {
                        count--;
                    }
                    if (part != null && n >= 2)
                    {
                        part[n++] = part[0];
                        part[n++] = part[1];
                    }
                }
                else
                {
                    throw new Error("MVT: unknown geometry command " + cmd);
                }
            }
            if (x0 <= x1)
            {
                minX = x0;
                minY = y0;
                maxX = x1;
                maxY = y1;
            }
            return parts;
        }
    }
}
