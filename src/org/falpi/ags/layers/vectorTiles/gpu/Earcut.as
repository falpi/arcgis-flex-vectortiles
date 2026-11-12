package org.falpi.ags.layers.vectorTiles.gpu
{
    /**
     * Polygon triangulation (ear clipping with hole elimination and z-order hashing).
     *
     * ActionScript port of earcut by Mapbox (https://github.com/mapbox/earcut), ISC License:
     *
     * Copyright (c) 2016, Mapbox
     *
     * Permission to use, copy, modify, and/or distribute this software for any purpose
     * with or without fee is hereby granted, provided that the above copyright notice
     * and this permission notice appear in all copies.
     *
     * THE SOFTWARE IS PROVIDED "AS IS" AND ISC DISCLAIMS ALL WARRANTIES WITH REGARD TO
     * THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS.
     * IN NO EVENT SHALL ISC BE LIABLE FOR ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL
     * DAMAGES OR ANY DAMAGES WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS,
     * WHETHER IN AN ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT
     * OF OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
     */
    public final class Earcut
    {
        /**
         * Triangulates one polygon.
         * @param data flat x,y coordinates: outer ring first, then the holes
         * @param holeIndices index (in vertices, not in numbers) where each hole starts, or null
         * @return vertex indices, three per triangle
         */
        /**
         * Diagonal tests left for the last resort of the current triangulation (splitting the polygon:
         * each test walks the whole ring, and degenerate input needs a quadratic number of them). When they
         * run out the polygon is left partly untriangulated instead of blocking the player for seconds.
         */
        private static var s_splitBudget:int;
        /** Diagnostics: polygons left partly untriangulated because the budget ran out. */
        public static var incomplete:int = 0;
        /** True when the last triangulation ran out of budget (its result is partial). */
        public static var lastIncomplete:Boolean = false;

        public static function triangulate(data:Vector.<Number>, holeIndices:Vector.<int> = null):Vector.<int>
        {
            // a few hundred thousand vertex visits at most (milliseconds, not seconds)
            s_splitBudget = Math.max(48, 4e5 / (data.length + 1));
            lastIncomplete = false;
            var hasHoles:Boolean = holeIndices != null && holeIndices.length > 0;
            var outerLen:int = hasHoles ? holeIndices[0] * 2 : data.length;
            var outerNode:EarNode = linkedList(data, 0, outerLen, true);
            var triangles:Vector.<int> = new Vector.<int>();
            if (outerNode == null || outerNode.next == outerNode.prev)
            {
                return triangles;
            }
            var minX:Number = 0;
            var minY:Number = 0;
            var invSize:Number = 0;
            if (hasHoles)
            {
                outerNode = eliminateHoles(data, holeIndices, outerNode);
            }
            // z-order hashing speeds up big polygons
            if (data.length > 80 * 2)
            {
                minX = data[0];
                minY = data[1];
                var maxX:Number = minX;
                var maxY:Number = minY;
                for (var i:int = 2; i < outerLen; i += 2)
                {
                    var x:Number = data[i];
                    var y:Number = data[i + 1];
                    if (x < minX) minX = x;
                    if (y < minY) minY = y;
                    if (x > maxX) maxX = x;
                    if (y > maxY) maxY = y;
                }
                invSize = Math.max(maxX - minX, maxY - minY);
                invSize = invSize != 0 ? 32767 / invSize : 0;
            }
            earcutLinked(outerNode, triangles, minX, minY, invSize, 0);
            return triangles;
        }

        /** Circular doubly linked list from the polygon points in the given winding order. */
        private static function linkedList(data:Vector.<Number>, start:int, end:int, clockwise:Boolean):EarNode
        {
            var i:int;
            var last:EarNode = null;
            if (clockwise == (signedArea(data, start, end) > 0))
            {
                for (i = start; i < end; i += 2)
                {
                    last = insertNode(i / 2, data[i], data[i + 1], last);
                }
            }
            else
            {
                for (i = end - 2; i >= start; i -= 2)
                {
                    last = insertNode(i / 2, data[i], data[i + 1], last);
                }
            }
            if (last != null && equals(last, last.next))
            {
                removeNode(last);
                last = last.next;
            }
            return last;
        }

        /** Eliminates colinear or duplicate points. */
        private static function filterPoints(start:EarNode, end:EarNode = null):EarNode
        {
            if (start == null)
            {
                return start;
            }
            if (end == null)
            {
                end = start;
            }
            var p:EarNode = start;
            var again:Boolean;
            do
            {
                again = false;
                if (!p.steiner && (equals(p, p.next) || area(p.prev, p, p.next) == 0))
                {
                    removeNode(p);
                    p = end = p.prev;
                    if (p == p.next)
                    {
                        break;
                    }
                    again = true;
                }
                else
                {
                    p = p.next;
                }
            }
            while (again || p != end);
            return end;
        }

        /** Main ear slicing loop. */
        private static function earcutLinked(ear:EarNode, triangles:Vector.<int>, minX:Number, minY:Number,
                                             invSize:Number, pass:int):void
        {
            if (ear == null)
            {
                return;
            }
            if (pass == 0 && invSize != 0)
            {
                indexCurve(ear, minX, minY, invSize);
            }
            var stop:EarNode = ear;
            var prev:EarNode;
            var next:EarNode;
            while (ear.prev != ear.next)
            {
                prev = ear.prev;
                next = ear.next;
                if (invSize != 0 ? isEarHashed(ear, minX, minY, invSize) : isEar(ear))
                {
                    triangles.push(prev.i, ear.i, next.i);
                    removeNode(ear);
                    // skipping the next vertex leads to less sliver triangles
                    ear = next.next;
                    stop = next.next;
                    continue;
                }
                ear = next;
                if (ear == stop)
                {
                    // no ears found: try filtering points and slicing again
                    if (pass == 0)
                    {
                        earcutLinked(filterPoints(ear), triangles, minX, minY, invSize, 1);
                    }
                    else if (pass == 1)
                    {
                        ear = cureLocalIntersections(filterPoints(ear), triangles);
                        earcutLinked(ear, triangles, minX, minY, invSize, 2);
                    }
                    else if (pass == 2)
                    {
                        splitEarcut(ear, triangles, minX, minY, invSize);
                    }
                    break;
                }
            }
        }

        /** Whether a polygon node forms a valid ear with adjacent nodes. */
        private static function isEar(ear:EarNode):Boolean
        {
            var a:EarNode = ear.prev;
            var b:EarNode = ear;
            var c:EarNode = ear.next;
            if (area(a, b, c) >= 0)
            {
                return false; // reflex, can't be an ear
            }
            var p:EarNode = ear.next.next;
            while (p != ear.prev)
            {
                if (pointInTriangle(a.x, a.y, b.x, b.y, c.x, c.y, p.x, p.y) && area(p.prev, p, p.next) >= 0)
                {
                    return false;
                }
                p = p.next;
            }
            return true;
        }

        private static function isEarHashed(ear:EarNode, minX:Number, minY:Number, invSize:Number):Boolean
        {
            var a:EarNode = ear.prev;
            var b:EarNode = ear;
            var c:EarNode = ear.next;
            if (area(a, b, c) >= 0)
            {
                return false;
            }
            var minTX:Number = a.x < b.x ? (a.x < c.x ? a.x : c.x) : (b.x < c.x ? b.x : c.x);
            var minTY:Number = a.y < b.y ? (a.y < c.y ? a.y : c.y) : (b.y < c.y ? b.y : c.y);
            var maxTX:Number = a.x > b.x ? (a.x > c.x ? a.x : c.x) : (b.x > c.x ? b.x : c.x);
            var maxTY:Number = a.y > b.y ? (a.y > c.y ? a.y : c.y) : (b.y > c.y ? b.y : c.y);
            var minZ:int = zOrder(minTX, minTY, minX, minY, invSize);
            var maxZ:int = zOrder(maxTX, maxTY, minX, minY, invSize);
            var p:EarNode = ear.prevZ;
            var n:EarNode = ear.nextZ;
            // look for points inside the triangle in both directions
            while (p != null && p.z >= minZ && n != null && n.z <= maxZ)
            {
                if (p != ear.prev && p != ear.next &&
                    pointInTriangle(a.x, a.y, b.x, b.y, c.x, c.y, p.x, p.y) && area(p.prev, p, p.next) >= 0)
                {
                    return false;
                }
                p = p.prevZ;
                if (n != ear.prev && n != ear.next &&
                    pointInTriangle(a.x, a.y, b.x, b.y, c.x, c.y, n.x, n.y) && area(n.prev, n, n.next) >= 0)
                {
                    return false;
                }
                n = n.nextZ;
            }
            while (p != null && p.z >= minZ)
            {
                if (p != ear.prev && p != ear.next &&
                    pointInTriangle(a.x, a.y, b.x, b.y, c.x, c.y, p.x, p.y) && area(p.prev, p, p.next) >= 0)
                {
                    return false;
                }
                p = p.prevZ;
            }
            while (n != null && n.z <= maxZ)
            {
                if (n != ear.prev && n != ear.next &&
                    pointInTriangle(a.x, a.y, b.x, b.y, c.x, c.y, n.x, n.y) && area(n.prev, n, n.next) >= 0)
                {
                    return false;
                }
                n = n.nextZ;
            }
            return true;
        }

        /** Goes through all polygon nodes and cures small local self-intersections. */
        private static function cureLocalIntersections(start:EarNode, triangles:Vector.<int>):EarNode
        {
            var p:EarNode = start;
            do
            {
                var a:EarNode = p.prev;
                var b:EarNode = p.next.next;
                if (!equals(a, b) && intersects(a, p, p.next, b) && locallyInside(a, b) && locallyInside(b, a))
                {
                    triangles.push(a.i, p.i, b.i);
                    removeNode(p);
                    removeNode(p.next);
                    p = start = b;
                }
                p = p.next;
            }
            while (p != start);
            return filterPoints(p);
        }

        /** Tries splitting the polygon into two and triangulates them independently. */
        private static function splitEarcut(start:EarNode, triangles:Vector.<int>, minX:Number, minY:Number,
                                            invSize:Number):void
        {
            var a:EarNode = start;
            do
            {
                var b:EarNode = a.next.next;
                while (b != a.prev)
                {
                    if (--s_splitBudget < 0)
                    {
                        if (!lastIncomplete)
                        {
                            lastIncomplete = true;
                            incomplete++;
                        }
                        return;
                    }
                    if (a.i != b.i && isValidDiagonal(a, b))
                    {
                        var c:EarNode = splitPolygon(a, b);
                        a = filterPoints(a, a.next);
                        c = filterPoints(c, c.next);
                        earcutLinked(a, triangles, minX, minY, invSize, 0);
                        earcutLinked(c, triangles, minX, minY, invSize, 0);
                        return;
                    }
                    b = b.next;
                }
                a = a.next;
            }
            while (a != start);
        }

        /** Links every hole into the outer loop, producing a single-ring polygon without holes. */
        private static function eliminateHoles(data:Vector.<Number>, holeIndices:Vector.<int>, outerNode:EarNode):EarNode
        {
            var queue:Array = [];
            var len:int = holeIndices.length;
            for (var i:int = 0; i < len; i++)
            {
                var start:int = holeIndices[i] * 2;
                var end:int = i < len - 1 ? holeIndices[i + 1] * 2 : data.length;
                var list:EarNode = linkedList(data, start, end, false);
                if (list == null)
                {
                    continue;
                }
                if (list == list.next)
                {
                    list.steiner = true;
                }
                queue.push(getLeftmost(list));
            }
            queue.sort(compareX);
            for (i = 0; i < queue.length; i++)
            {
                outerNode = eliminateHole(queue[i], outerNode);
            }
            return outerNode;
        }

        private static function compareX(a:EarNode, b:EarNode):Number
        {
            return a.x - b.x;
        }

        /** Finds a bridge between a hole and the outer polygon and links it. */
        private static function eliminateHole(hole:EarNode, outerNode:EarNode):EarNode
        {
            var bridge:EarNode = findHoleBridge(hole, outerNode);
            if (bridge == null)
            {
                return outerNode;
            }
            var bridgeReverse:EarNode = splitPolygon(bridge, hole);
            filterPoints(bridgeReverse, bridgeReverse.next);
            return filterPoints(bridge, bridge.next);
        }

        /** David Eberly's algorithm for finding a bridge between hole and outer polygon. */
        private static function findHoleBridge(hole:EarNode, outerNode:EarNode):EarNode
        {
            var p:EarNode = outerNode;
            var hx:Number = hole.x;
            var hy:Number = hole.y;
            var qx:Number = -Infinity;
            var m:EarNode = null;
            // find a segment intersected by a ray from the hole's leftmost point to the left;
            // segment's endpoint with lesser x will be potential connection point
            do
            {
                if (hy <= p.y && hy >= p.next.y && p.next.y != p.y)
                {
                    var x:Number = p.x + (hy - p.y) * (p.next.x - p.x) / (p.next.y - p.y);
                    if (x <= hx && x > qx)
                    {
                        qx = x;
                        m = p.x < p.next.x ? p : p.next;
                        if (x == hx)
                        {
                            return m; // hole touches outer segment; pick leftmost endpoint
                        }
                    }
                }
                p = p.next;
            }
            while (p != outerNode);
            if (m == null)
            {
                return null;
            }
            // look for points inside the triangle of hole point, segment intersection and endpoint;
            // if there are no points found, we have a valid connection;
            // otherwise choose the point of the minimum angle with the ray as connection point
            var stop:EarNode = m;
            var mx:Number = m.x;
            var my:Number = m.y;
            var tanMin:Number = Infinity;
            p = m;
            do
            {
                if (hx >= p.x && p.x >= mx && hx != p.x &&
                    pointInTriangle(hy < my ? hx : qx, hy, mx, my, hy < my ? qx : hx, hy, p.x, p.y))
                {
                    var tan:Number = Math.abs(hy - p.y) / (hx - p.x); // tangential
                    if (locallyInside(p, hole) &&
                        (tan < tanMin || (tan == tanMin && (p.x > m.x || (p.x == m.x && sectorContainsSector(m, p))))))
                    {
                        m = p;
                        tanMin = tan;
                    }
                }
                p = p.next;
            }
            while (p != stop);
            return m;
        }

        /** Whether sector in vertex m contains sector in vertex p in the same coordinates. */
        private static function sectorContainsSector(m:EarNode, p:EarNode):Boolean
        {
            return area(m.prev, m, p.prev) < 0 && area(p.next, m, m.next) < 0;
        }

        /** Interlinks polygon nodes in z-order. */
        private static function indexCurve(start:EarNode, minX:Number, minY:Number, invSize:Number):void
        {
            var p:EarNode = start;
            do
            {
                if (p.z == 0)
                {
                    p.z = zOrder(p.x, p.y, minX, minY, invSize);
                }
                p.prevZ = p.prev;
                p.nextZ = p.next;
                p = p.next;
            }
            while (p != start);
            p.prevZ.nextZ = null;
            p.prevZ = null;
            sortLinked(p);
        }

        /** Simon Tatham's linked list merge sort algorithm. */
        private static function sortLinked(list:EarNode):EarNode
        {
            var inSize:int = 1;
            var numMerges:int;
            do
            {
                var p:EarNode = list;
                list = null;
                var tail:EarNode = null;
                numMerges = 0;
                while (p != null)
                {
                    numMerges++;
                    var q:EarNode = p;
                    var pSize:int = 0;
                    for (var i:int = 0; i < inSize; i++)
                    {
                        pSize++;
                        q = q.nextZ;
                        if (q == null)
                        {
                            break;
                        }
                    }
                    var qSize:int = inSize;
                    while (pSize > 0 || (qSize > 0 && q != null))
                    {
                        var e:EarNode;
                        if (pSize != 0 && (qSize == 0 || q == null || p.z <= q.z))
                        {
                            e = p;
                            p = p.nextZ;
                            pSize--;
                        }
                        else
                        {
                            e = q;
                            q = q.nextZ;
                            qSize--;
                        }
                        if (tail != null)
                        {
                            tail.nextZ = e;
                        }
                        else
                        {
                            list = e;
                        }
                        e.prevZ = tail;
                        tail = e;
                    }
                    p = q;
                }
                tail.nextZ = null;
                inSize *= 2;
            }
            while (numMerges > 1);
            return list;
        }

        /** z-order of a point given coords and inverse of the longer side of data bbox. */
        private static function zOrder(px:Number, py:Number, minX:Number, minY:Number, invSize:Number):int
        {
            var x:int = int((px - minX) * invSize);
            var y:int = int((py - minY) * invSize);
            x = (x | (x << 8)) & 0x00FF00FF;
            x = (x | (x << 4)) & 0x0F0F0F0F;
            x = (x | (x << 2)) & 0x33333333;
            x = (x | (x << 1)) & 0x55555555;
            y = (y | (y << 8)) & 0x00FF00FF;
            y = (y | (y << 4)) & 0x0F0F0F0F;
            y = (y | (y << 2)) & 0x33333333;
            y = (y | (y << 1)) & 0x55555555;
            return x | (y << 1);
        }

        /** The leftmost node of a polygon ring. */
        private static function getLeftmost(start:EarNode):EarNode
        {
            var p:EarNode = start;
            var leftmost:EarNode = start;
            do
            {
                if (p.x < leftmost.x || (p.x == leftmost.x && p.y < leftmost.y))
                {
                    leftmost = p;
                }
                p = p.next;
            }
            while (p != start);
            return leftmost;
        }

        /** Whether a point lies within a convex triangle. */
        private static function pointInTriangle(ax:Number, ay:Number, bx:Number, by:Number, cx:Number, cy:Number,
                                                px:Number, py:Number):Boolean
        {
            return (cx - px) * (ay - py) >= (ax - px) * (cy - py) &&
                   (ax - px) * (by - py) >= (bx - px) * (ay - py) &&
                   (bx - px) * (cy - py) >= (cx - px) * (by - py);
        }

        /** Whether a diagonal between two polygon nodes is valid (lies in polygon interior). */
        private static function isValidDiagonal(a:EarNode, b:EarNode):Boolean
        {
            return a.next.i != b.i && a.prev.i != b.i && !intersectsPolygon(a, b) &&
                   ((locallyInside(a, b) && locallyInside(b, a) && middleInside(a, b) &&
                     (area(a.prev, a, b.prev) != 0 || area(a, b.prev, b) != 0)) ||
                    (equals(a, b) && area(a.prev, a, a.next) > 0 && area(b.prev, b, b.next) > 0));
        }

        /** Signed area of a triangle. */
        private static function area(p:EarNode, q:EarNode, r:EarNode):Number
        {
            return (q.y - p.y) * (r.x - q.x) - (q.x - p.x) * (r.y - q.y);
        }

        private static function equals(p1:EarNode, p2:EarNode):Boolean
        {
            return p1.x == p2.x && p1.y == p2.y;
        }

        /** Whether two segments intersect. */
        private static function intersects(p1:EarNode, q1:EarNode, p2:EarNode, q2:EarNode):Boolean
        {
            var o1:int = sign(area(p1, q1, p2));
            var o2:int = sign(area(p1, q1, q2));
            var o3:int = sign(area(p2, q2, p1));
            var o4:int = sign(area(p2, q2, q1));
            if (o1 != o2 && o3 != o4) return true; // general case
            if (o1 == 0 && onSegment(p1, p2, q1)) return true; // p1, q1 and p2 are collinear and p2 lies on p1q1
            if (o2 == 0 && onSegment(p1, q2, q1)) return true;
            if (o3 == 0 && onSegment(p2, p1, q2)) return true;
            if (o4 == 0 && onSegment(p2, q1, q2)) return true;
            return false;
        }

        /** For collinear points p, q, r: whether point q lies on segment pr. */
        private static function onSegment(p:EarNode, q:EarNode, r:EarNode):Boolean
        {
            return q.x <= Math.max(p.x, r.x) && q.x >= Math.min(p.x, r.x) &&
                   q.y <= Math.max(p.y, r.y) && q.y >= Math.min(p.y, r.y);
        }

        private static function sign(num:Number):int
        {
            return num > 0 ? 1 : (num < 0 ? -1 : 0);
        }

        /** Whether a polygon diagonal intersects any polygon segments. */
        private static function intersectsPolygon(a:EarNode, b:EarNode):Boolean
        {
            var p:EarNode = a;
            do
            {
                if (p.i != a.i && p.next.i != a.i && p.i != b.i && p.next.i != b.i && intersects(p, p.next, a, b))
                {
                    return true;
                }
                p = p.next;
            }
            while (p != a);
            return false;
        }

        /** Whether a polygon diagonal is locally inside the polygon. */
        private static function locallyInside(a:EarNode, b:EarNode):Boolean
        {
            return area(a.prev, a, a.next) < 0 ?
                area(a, b, a.next) >= 0 && area(a, a.prev, b) >= 0 :
                area(a, b, a.prev) < 0 || area(a, a.next, b) < 0;
        }

        /** Whether the middle point of a polygon diagonal is inside the polygon. */
        private static function middleInside(a:EarNode, b:EarNode):Boolean
        {
            var p:EarNode = a;
            var inside:Boolean = false;
            var px:Number = (a.x + b.x) / 2;
            var py:Number = (a.y + b.y) / 2;
            do
            {
                if (((p.y > py) != (p.next.y > py)) && p.next.y != p.y &&
                    (px < (p.next.x - p.x) * (py - p.y) / (p.next.y - p.y) + p.x))
                {
                    inside = !inside;
                }
                p = p.next;
            }
            while (p != a);
            return inside;
        }

        /**
         * Links two polygon vertices with a bridge; if the vertices belong to the same ring, it splits
         * polygon into two; if one belongs to the outer ring and another to a hole, it merges it into one.
         */
        private static function splitPolygon(a:EarNode, b:EarNode):EarNode
        {
            var a2:EarNode = new EarNode(a.i, a.x, a.y);
            var b2:EarNode = new EarNode(b.i, b.x, b.y);
            var an:EarNode = a.next;
            var bp:EarNode = b.prev;
            a.next = b;
            b.prev = a;
            a2.next = an;
            an.prev = a2;
            b2.next = a2;
            a2.prev = b2;
            bp.next = b2;
            b2.prev = bp;
            return b2;
        }

        /** Creates a node and optionally links it with the previous one (in a circular doubly linked list). */
        private static function insertNode(i:int, x:Number, y:Number, last:EarNode):EarNode
        {
            var p:EarNode = new EarNode(i, x, y);
            if (last == null)
            {
                p.prev = p;
                p.next = p;
            }
            else
            {
                p.next = last.next;
                p.prev = last;
                last.next.prev = p;
                last.next = p;
            }
            return p;
        }

        private static function removeNode(p:EarNode):void
        {
            p.next.prev = p.prev;
            p.prev.next = p.next;
            if (p.prevZ != null)
            {
                p.prevZ.nextZ = p.nextZ;
            }
            if (p.nextZ != null)
            {
                p.nextZ.prevZ = p.prevZ;
            }
        }

        private static function signedArea(data:Vector.<Number>, start:int, end:int):Number
        {
            var sum:Number = 0;
            for (var i:int = start, j:int = end - 2; i < end; i += 2)
            {
                sum += (data[j] - data[i]) * (data[i + 1] + data[j + 1]);
                j = i;
            }
            return sum;
        }
    }
}

/** A vertex of the polygon linked lists. */
final class EarNode
{
    public var i:int;
    public var x:Number;
    public var y:Number;
    public var prev:EarNode;
    public var next:EarNode;
    public var z:int = 0;
    public var prevZ:EarNode;
    public var nextZ:EarNode;
    public var steiner:Boolean = false;

    public function EarNode(i:int, x:Number, y:Number)
    {
        this.i = i;
        this.x = x;
        this.y = y;
    }
}
