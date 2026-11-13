package org.falpi.ags.layers.vectorTiles.labels
{
    /** Grid index of the screen boxes already taken by placed symbols. */
    public final class CollisionIndex
    {
        private static const CELL:Number = 48;

        private var m_cells:Object = {};

        /**
         * Added to the coordinates of every box: the position of the overlay being placed. The boxes are kept
         * in layer coordinates, so that a later placement on an overlay with another origin still sees them.
         */
        public var offsetX:Number = 0;
        public var offsetY:Number = 0;

        public function clear():void
        {
            m_cells = {};
        }

        /** True when the box overlaps a box already inserted. */
        public function collides(x1:Number, y1:Number, x2:Number, y2:Number):Boolean
        {
            x1 += offsetX;
            x2 += offsetX;
            y1 += offsetY;
            y2 += offsetY;
            var cx1:int = Math.floor(x1 / CELL);
            var cy1:int = Math.floor(y1 / CELL);
            var cx2:int = Math.floor(x2 / CELL);
            var cy2:int = Math.floor(y2 / CELL);
            for (var cx:int = cx1; cx <= cx2; cx++)
            {
                for (var cy:int = cy1; cy <= cy2; cy++)
                {
                    var boxes:Vector.<Number> = m_cells[cx * 65536 + cy] as Vector.<Number>;
                    if (boxes == null)
                    {
                        continue;
                    }
                    var n:int = boxes.length;
                    for (var i:int = 0; i < n; i += 4)
                    {
                        if (x1 < boxes[int(i + 2)] && x2 > boxes[i] && y1 < boxes[int(i + 3)] && y2 > boxes[int(i + 1)])
                        {
                            return true;
                        }
                    }
                }
            }
            return false;
        }

        public function insert(x1:Number, y1:Number, x2:Number, y2:Number):void
        {
            x1 += offsetX;
            x2 += offsetX;
            y1 += offsetY;
            y2 += offsetY;
            var cx1:int = Math.floor(x1 / CELL);
            var cy1:int = Math.floor(y1 / CELL);
            var cx2:int = Math.floor(x2 / CELL);
            var cy2:int = Math.floor(y2 / CELL);
            for (var cx:int = cx1; cx <= cx2; cx++)
            {
                for (var cy:int = cy1; cy <= cy2; cy++)
                {
                    var key:int = cx * 65536 + cy;
                    var boxes:Vector.<Number> = m_cells[key] as Vector.<Number>;
                    if (boxes == null)
                    {
                        boxes = new Vector.<Number>();
                        m_cells[key] = boxes;
                    }
                    boxes.push(x1, y1, x2, y2);
                }
            }
        }
    }
}
