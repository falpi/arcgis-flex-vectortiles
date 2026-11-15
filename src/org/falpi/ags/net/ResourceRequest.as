package org.falpi.ags.net
{
    import flash.net.URLLoader;

    /** Handle of a request queued on a ResourceLoader. */
    public final class ResourceRequest
    {
        public var url:String;
        public var binary:Boolean;
        /** Sent straight to its server, without the proxy (the token is still applied). */
        public var direct:Boolean = false;
        public var onComplete:Function;
        public var onError:Function;
        /** HTTP status when the runtime reports it, otherwise 0. */
        public var status:int = 0;
        public var cancelled:Boolean = false;
        public var finished:Boolean = false;
        /** Free slot for the caller. */
        public var context:Object;

        internal var loader:URLLoader;
        /** Id of the request made by the page (JavaScriptTransport), 0 when Flash makes it. */
        internal var scriptId:int = 0;
        internal var handler:Function;
    }
}
