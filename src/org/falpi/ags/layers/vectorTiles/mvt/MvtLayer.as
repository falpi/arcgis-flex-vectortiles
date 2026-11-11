package org.falpi.ags.layers.vectorTiles.mvt
{
    import org.falpi.ags.layers.vectorTiles.pbf.PbfReader;

    import flash.utils.ByteArray;

    /** One named layer of a vector tile. */
    public final class MvtLayer
    {
        public var name:String;
        public var version:uint = 1;
        public var extent:uint = 4096;

        private var m_bytes:ByteArray;
        private var m_keys:Array = [];
        private var m_values:Array = [];
        private var m_featureStarts:Vector.<uint> = new Vector.<uint>();
        private var m_featureLengths:Vector.<uint> = new Vector.<uint>();
        private var m_features:Vector.<MvtFeature>;

        public function MvtLayer(bytes:ByteArray, start:uint, length:uint)
        {
            m_bytes = bytes;
            var pbf:PbfReader = new PbfReader(bytes, start, length);
            while (pbf.next())
            {
                switch (pbf.tag)
                {
                    case 1:
                        name = pbf.readString();
                        break;
                    case 2:
                        m_featureStarts.push(pbf.readRange());
                        m_featureLengths.push(pbf.lastLength);
                        break;
                    case 3:
                        m_keys.push(pbf.readString());
                        break;
                    case 4:
                        m_values.push(readValue(pbf));
                        break;
                    case 5:
                        extent = pbf.readVarint();
                        break;
                    case 15:
                        version = pbf.readVarint();
                        break;
                    default:
                        pbf.skip();
                }
            }
        }

        public function get length():uint
        {
            return m_featureStarts.length;
        }

        /** All features of the layer (decoded on first access, geometry excluded). */
        public function get features():Vector.<MvtFeature>
        {
            if (m_features == null)
            {
                var n:uint = m_featureStarts.length;
                m_features = new Vector.<MvtFeature>(n, true);
                for (var i:uint = 0; i < n; i++)
                {
                    m_features[i] = new MvtFeature(m_bytes, m_featureStarts[i], m_featureLengths[i], m_keys, m_values, extent);
                }
            }
            return m_features;
        }

        private static function readValue(pbf:PbfReader):*
        {
            var start:uint = pbf.readRange();
            var sub:PbfReader = new PbfReader(pbf.buf, start, pbf.lastLength);
            var value:* = null;
            while (sub.next())
            {
                switch (sub.tag)
                {
                    case 1:
                        value = sub.readString();
                        break;
                    case 2:
                        value = sub.readFloat();
                        break;
                    case 3:
                        value = sub.readDouble();
                        break;
                    case 4:
                        value = sub.readInt64();
                        break;
                    case 5:
                        value = sub.readVarint64();
                        break;
                    case 6:
                        value = sub.readSVarint64();
                        break;
                    case 7:
                        value = sub.readVarint() != 0;
                        break;
                    default:
                        sub.skip();
                }
            }
            return value;
        }
    }
}
