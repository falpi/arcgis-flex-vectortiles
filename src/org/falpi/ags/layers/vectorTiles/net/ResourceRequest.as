package org.falpi.ags.layers.vectorTiles.net
{
    import flash.net.URLLoader;

    /** Handle of a request queued on a ResourceLoader. */
    public final class ResourceRequest
    {
        public var url:String;
        public var binary:Boolean;
        public var onComplete:Function;
        public var onError:Function;
        /** HTTP status when the runtime reports it, otherwise 0. */
        public var status:int = 0;
        public var cancelled:Boolean = false;
        public var finished:Boolean = false;
        /** Free slot for the caller. */
        public var context:Object;

        internal var loader:URLLoader;
        internal var handler:Function;
    }
}
