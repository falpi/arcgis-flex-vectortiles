package org.falpi.ags.layers.vectorTiles.render
{
    import org.falpi.ags.layers.vectorTiles.mvt.MvtFeature;
    import org.falpi.ags.layers.vectorTiles.style.StyleColor;
    import org.falpi.ags.layers.vectorTiles.style.StyleLayer;

    /**
     * What one fill, line or circle style layer draws from one data tile at one zoom, independent of
     * how it is drawn (CPU Graphics or GPU): the features that pass the filter and have the right
     * geometry type, in drawing order, with the paint values already evaluated. Geometry stays in
     * tile extent units (MvtFeature.loadGeometry), so one bucket serves every tile drawn from the data
     * tile, overzoomed ones included. Built and cached by BucketBuilder.
     *
     * With perFeature == false the paint is constant and lives in the scalar fields; otherwise the
     * vectors hold one value per feature (same index as features).
     */
    public final class LayerBucket
    {
        public static const FILL:int = 1;
        public static const LINE:int = 2;
        public static const CIRCLE:int = 3;

        public var kind:int;
        public var layer:StyleLayer;
        public var zoom:Number;
        public var features:Vector.<MvtFeature> = new Vector.<MvtFeature>();

        /** True when the (constant) paint makes the layer invisible: nothing to draw. */
        public var empty:Boolean = false;
        public var perFeature:Boolean = false;
        /**
         * Opacity applied to the layer as a whole (constant opacity &lt; 1): the features are drawn opaque
         * and the layer is blended once, so overlapping features of the same layer do not add up.
         */
        public var groupAlpha:Number = 1;
        /** *-translate, in pixels. */
        public var translateX:Number = 0;
        public var translateY:Number = 0;

        // fill ---------------------------------------------------------------
        public var antialias:Boolean = true;
        public var fillColor:StyleColor;
        public var fillOpacity:Number = 1;
        public var outlineColor:StyleColor;
        /** Sprite name of fill-pattern (only names present in the sprite atlas), or null. */
        public var patternName:String;
        public var fillColors:Vector.<StyleColor>;
        public var fillOpacities:Vector.<Number>;
        public var outlineColors:Vector.<StyleColor>;
        public var patternNames:Vector.<String>;

        // line ---------------------------------------------------------------
        public var lineRgb:uint;
        public var lineAlpha:Number = 1;
        /** Drawn width in pixels (line-gap-width already folded in). */
        public var lineWidth:Number = 1;
        public var lineRgbs:Vector.<uint>;
        public var lineAlphas:Vector.<Number>;
        public var lineWidths:Vector.<Number>;
        /** flash.display.CapsStyle / JointStyle values. */
        public var caps:String;
        public var joints:String;
        public var miterLimit:Number = 2;
        /** line-dasharray (in line widths), or null. */
        public var dashes:Array;

        // circle -------------------------------------------------------------
        public var radii:Vector.<Number>;
        public var circleRgbs:Vector.<uint>;
        public var circleAlphas:Vector.<Number>;
        public var strokeWidths:Vector.<Number>;
        public var strokeRgbs:Vector.<uint>;
        public var strokeAlphas:Vector.<Number>;

        public function LayerBucket(kind:int, layer:StyleLayer, zoom:Number)
        {
            this.kind = kind;
            this.layer = layer;
            this.zoom = zoom;
        }
    }
}
