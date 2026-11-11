package org.falpi.ags.layers.vectorTiles.pbf
{
    import flash.utils.ByteArray;
    import flash.utils.Endian;

    /**
     * Minimal Protocol Buffers reader working directly on a ByteArray window.
     * Only what Mapbox Vector Tiles and glyph PBFs need.
     */
    public final class PbfReader
    {
        public static const VARINT:uint = 0;
        public static const FIXED64:uint = 1;
        public static const BYTES:uint = 2;
        public static const FIXED32:uint = 5;

        public var buf:ByteArray;
        public var pos:uint;
        public var end:uint;

        /** Field number of the last key read by next(). */
        public var tag:uint;
        /** Wire type of the last key read by next(). */
        public var wireType:uint;

        public function PbfReader(bytes:ByteArray, start:uint = 0, length:int = -1)
        {
            buf = bytes;
            buf.endian = Endian.LITTLE_ENDIAN;
            pos = start;
            end = length < 0 ? bytes.length : start + length;
        }

        /** Reads the next field key. Returns false at the end of the window. */
        public function next():Boolean
        {
            if (pos >= end)
            {
                return false;
            }
            var key:uint = readVarint();
            tag = key >>> 3;
            wireType = key & 7;
            return true;
        }

        /** Reads a varint keeping the low 32 bits. */
        public function readVarint():uint
        {
            var b:uint = buf[pos++];
            var result:uint = b & 0x7f;
            if (b < 0x80) return result;
            b = buf[pos++];
            result |= (b & 0x7f) << 7;
            if (b < 0x80) return result;
            b = buf[pos++];
            result |= (b & 0x7f) << 14;
            if (b < 0x80) return result;
            b = buf[pos++];
            result |= (b & 0x7f) << 21;
            if (b < 0x80) return result;
            b = buf[pos++];
            result |= (b & 0x0f) << 28;
            while (b >= 0x80 && pos < end)
            {
                b = buf[pos++];
            }
            return result;
        }

        /** Reads a varint as an unsigned 64 bit value (Number precision). */
        public function readVarint64():Number
        {
            var result:Number = 0;
            var factor:Number = 1;
            var b:uint;
            do
            {
                b = buf[pos++];
                result += (b & 0x7f) * factor;
                factor *= 128;
            } while (b >= 0x80 && pos < end);
            return result;
        }

        /** Reads an int64 varint (two's complement negative numbers supported). */
        public function readInt64():Number
        {
            var value:Number = readVarint64();
            if (value >= 9223372036854775808)
            {
                value -= 18446744073709551616;
            }
            return value;
        }

        /** Reads a zigzag encoded 32 bit value. */
        public function readSVarint():int
        {
            var value:uint = readVarint();
            return int(value >>> 1) ^ -int(value & 1);
        }

        /** Reads a zigzag encoded 64 bit value. */
        public function readSVarint64():Number
        {
            var value:Number = readVarint64();
            return (value % 2 == 0) ? value / 2 : -(value + 1) / 2;
        }

        public function readFloat():Number
        {
            buf.position = pos;
            pos += 4;
            return buf.readFloat();
        }

        public function readDouble():Number
        {
            buf.position = pos;
            pos += 8;
            return buf.readDouble();
        }

        public function readString():String
        {
            var length:uint = readVarint();
            buf.position = pos;
            pos += length;
            return buf.readUTFBytes(length);
        }

        /** Copies a length delimited field into a new ByteArray. */
        public function readBytes():ByteArray
        {
            var length:uint = readVarint();
            var out:ByteArray = new ByteArray();
            if (length > 0)
            {
                buf.position = pos;
                buf.readBytes(out, 0, length);
            }
            pos += length;
            return out;
        }

        /**
         * Reads the length of a length delimited field and skips over it.
         * The payload is [result, result + lastLength).
         */
        public function readRange():uint
        {
            lastLength = readVarint();
            var start:uint = pos;
            pos += lastLength;
            return start;
        }

        /** Length of the field consumed by the last readRange() call. */
        public var lastLength:uint;

        /** Skips the value of the field whose key was just read. */
        public function skip():void
        {
            switch (wireType)
            {
                case VARINT:
                    while (buf[pos++] >= 0x80 && pos < end)
                    {
                    }
                    break;
                case FIXED64:
                    pos += 8;
                    break;
                case BYTES:
                    // two statements: readVarint() moves pos itself
                    var length:uint = readVarint();
                    pos += length;
                    break;
                case FIXED32:
                    pos += 4;
                    break;
                default:
                    throw new Error("PBF: unsupported wire type " + wireType);
            }
        }
    }
}
