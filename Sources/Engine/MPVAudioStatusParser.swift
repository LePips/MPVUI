enum MPVAudioStatusParser {
    static func parse(
        output: String?, codec: String?, sourceChannels: String?,
        outputChannels: String?, outputFormat: String?, native: MPVNodeValue?
    ) -> MPVAudioStatus {
        var result = MPVAudioStatus()
        result.output = output
        result.codec = codec
        result.sourceChannels = sourceChannels
        result.outputChannels = outputChannels
        result.outputFormat = outputFormat
        // A stale/foreign native node cannot establish the active output's state.
        if output == "avfoundation", let fields = native?.mapValue {
            result.nativePath = fields["path"]?.stringValue
            result.allowsStereoSpatialization = fields["allows-stereo"]?.boolValue
            result.allowsMultichannelSpatialization = fields["allows-multichannel"]?.boolValue
            result.routeSpatialAudioEnabled = fields["route-spatial-enabled"]?.boolValue
        }
        return result
    }
}
