package org.falpi.ags.layers.vectorTiles.gpu
{
    import flash.utils.ByteArray;
    import flash.utils.Endian;

    /**
     * Minimal AGAL (version 1) assembler for the few shaders of the GPU renderer.
     * One instruction per line: "opcode dest, source1[, source2]", for example
     * "mul vt0.xy, va0.xy, vc0.xy". Registers: va (attribute), vc/fc (constant), vt/ft (temporary),
     * op/oc (output), v (varying). Opcodes: mov, add, sub, mul, div, rcp, min, max, frc, abs, neg,
     * sat, m44, and
     * "kil source" (discards the fragment when the source component is negative).
     * No samplers, no indirect addressing (not needed so far).
     */
    public final class Agal
    {
        private static const OPCODES:Object = {mov: 0x00, add: 0x01, sub: 0x02, mul: 0x03, div: 0x04,
            rcp: 0x05, min: 0x06, max: 0x07, frc: 0x08, abs: 0x14, neg: 0x15, sat: 0x16, m44: 0x18, kil: 0x27};
        private static const TYPES:Object = {va: 0, vc: 1, fc: 1, vt: 2, ft: 2, op: 3, oc: 3, v: 4};
        private static const COMPONENTS:String = "xyzw";

        public static function assemble(fragment:Boolean, source:String):ByteArray
        {
            var b:ByteArray = new ByteArray();
            b.endian = Endian.LITTLE_ENDIAN;
            b.writeByte(0xA0);
            b.writeUnsignedInt(1);
            b.writeByte(0xA1);
            b.writeByte(fragment ? 1 : 0);
            for each (var line:String in source.split("\n"))
            {
                line = line.replace(/\/\/.*$/, "").replace(/^\s+|\s+$/g, "");
                if (line.length == 0)
                {
                    continue;
                }
                var space:int = line.indexOf(" ");
                var name:String = line.substr(0, space);
                if (!OPCODES.hasOwnProperty(name))
                {
                    throw new Error("AGAL: unknown opcode in '" + line + "'");
                }
                var operands:Array = line.substr(space + 1).split(",");
                b.writeUnsignedInt(OPCODES[name]);
                if (name == "kil")
                {
                    // no destination: the operand is the first source
                    b.writeUnsignedInt(0);
                    writeSource(b, trim(operands[0]));
                    writeSource(b, null);
                    continue;
                }
                writeDestination(b, trim(operands[0]));
                writeSource(b, operands.length > 1 ? trim(operands[1]) : null);
                writeSource(b, operands.length > 2 ? trim(operands[2]) : null);
            }
            return b;
        }

        private static function trim(s:String):String
        {
            return s.replace(/^\s+|\s+$/g, "");
        }

        /** [type, number, components] of "vt0.xy". */
        private static function parse(token:String):Array
        {
            var match:Array = /^([a-z]+?)(\d*)(?:\.([xyzw]{1,4}))?$/.exec(token);
            if (match == null || !TYPES.hasOwnProperty(match[1]))
            {
                throw new Error("AGAL: bad register '" + token + "'");
            }
            return [TYPES[match[1]], match[2].length > 0 ? int(match[2]) : 0, match[3]];
        }

        private static function writeDestination(b:ByteArray, token:String):void
        {
            var r:Array = parse(token);
            var mask:int = 0;
            var components:String = r[2] != null ? r[2] : "xyzw";
            for (var i:int = 0; i < components.length; i++)
            {
                mask |= 1 << COMPONENTS.indexOf(components.charAt(i));
            }
            b.writeShort(r[1]);
            b.writeByte(mask);
            b.writeByte(r[0]);
        }

        private static function writeSource(b:ByteArray, token:String):void
        {
            if (token == null)
            {
                b.writeUnsignedInt(0);
                b.writeUnsignedInt(0);
                return;
            }
            var r:Array = parse(token);
            var components:String = r[2] != null ? r[2] : "xyzw";
            var swizzle:int = 0;
            for (var i:int = 0; i < 4; i++)
            {
                // a short swizzle repeats its last component
                var c:String = components.charAt(Math.min(i, components.length - 1));
                swizzle |= COMPONENTS.indexOf(c) << (i * 2);
            }
            b.writeShort(r[1]);
            b.writeByte(0);        // indirect offset
            b.writeByte(swizzle);
            b.writeByte(r[0]);     // register type
            b.writeByte(0);        // index register type
            b.writeShort(0);       // index select / direct addressing
        }
    }
}
