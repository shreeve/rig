comptime {
    @compileLog(@alignOf(@Vector(16, u8)), @alignOf(@Vector(32, u8)), @alignOf(@Vector(64, u8)), @sizeOf(@Vector(64, bool)), @sizeOf(@Vector(16, u3)));
}
