# MPVKit attribution

MPVUI's native build recipes originate from [MPVKit](https://github.com/mpvkit/MPVKit). The imported recipe revision and source identities are recorded in [Build/Inputs.lock.json](../../Build/Inputs.lock.json); recipe attribution is preserved in [Build/RECIPE_LICENSE](../../Build/RECIPE_LICENSE).

Native compilation and packaging are implemented by [Build](../../Build), invoked through `Build/mpvbuild`. This directory is not a separate Swift package or native build entry point. See [build and development guide](../../Build/BUILD.md).

## License

The imported MPVKit recipe source is covered by its [GNU Lesser General Public License v3.0](LICENSE). MPVUI uses GPL-enabled mpv and FFmpeg configurations and retains the `Libmpv-GPL` target name. Applicable mpv, FFmpeg, MPVKit, and third-party license terms continue to apply to distributed binaries.
