package struct MPVEngineEmission: Sendable {

    package let generation: UInt64?
    package let update: MPVEngineUpdate
    package let snapshot: MPVSessionSnapshot

    package init(generation: UInt64?, update: MPVEngineUpdate, snapshot: MPVSessionSnapshot) {
        self.generation = generation
        self.update = update
        self.snapshot = snapshot
    }
}
