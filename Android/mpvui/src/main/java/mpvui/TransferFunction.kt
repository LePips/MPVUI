package mpvui

/** Reported signal transfer characteristics. Unrecognized values use [OTHER]. */
enum class TransferFunction(val mpvValue: String?) {
    UNKNOWN(null), BT709("bt.709"), BT1886("bt.1886"), SRGB("srgb"), LINEAR("linear"),
    GAMMA18("gamma1.8"), GAMMA20("gamma2.0"), GAMMA22("gamma2.2"), GAMMA24("gamma2.4"),
    GAMMA26("gamma2.6"), GAMMA28("gamma2.8"), PQ("pq"), HLG("hlg"), OTHER(null);

    /** Whether the transfer function identifies PQ or HLG video. */
    val isHDR: Boolean get() = this == PQ || this == HLG

}
