import sys; sys.path.insert(0, sys.argv[1]); from sub import sub
sub('checker.zig', '    pub fn inference_type_mapper_map(self: *Checker,', '    pub noinline fn inference_type_mapper_map(self: *Checker,')
sub('checker.zig', '    pub fn function_mapper_map(self: *Checker,', '    pub noinline fn function_mapper_map(self: *Checker,')
