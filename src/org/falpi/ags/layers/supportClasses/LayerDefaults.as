package org.falpi.ags.layers.supportClasses
{
    /**
     * The mechanism shared by the objects of defaults (<code>AbstractTileLayer.defaults</code>,
     * <code>RasterTileLayer.defaults</code>, <code>VectorTileLayer.defaults</code>,
     * <code>HybridTileLayer.defaults</code>): each starts with its initial values, a setting set to null (NaN for
     * numbers) or <code>clear</code> goes back to how it started, and <code>isSet</code> tells whether the object
     * has a value of its own. The subclasses declare the settings.
     */
    public class LayerDefaults
    {
        private var m_initial:Object;
        private var m_values:Object;

        /** @param initial the values it starts with (and goes back to with clear) */
        public function LayerDefaults(initial:Object = null)
        {
            m_initial = initial != null ? initial : {};
            clear();
        }

        /** Whether this object has a value for the setting. */
        public function isSet(name:String):Boolean
        {
            return m_values.hasOwnProperty(name);
        }

        /** Brings one setting (or all of them) back to how the object started. */
        public function clear(name:String = null):void
        {
            if (name == null)
            {
                m_values = {};
                for (var key:String in m_initial)
                {
                    m_values[key] = m_initial[key];
                }
            }
            else if (m_initial.hasOwnProperty(name))
            {
                m_values[name] = m_initial[name];
            }
            else
            {
                delete m_values[name];
            }
        }

        /** The value of a setting; undefined when there is none. */
        public function getValue(name:String):*
        {
            return m_values.hasOwnProperty(name) ? m_values[name] : undefined;
        }

        /** Sets a value; null (NaN for numbers) brings the setting back to how the object started. */
        protected function store(name:String, value:*):void
        {
            if (value === null || value === undefined || (value is Number && isNaN(value)))
            {
                clear(name);
            }
            else
            {
                m_values[name] = value;
            }
        }
    }
}
