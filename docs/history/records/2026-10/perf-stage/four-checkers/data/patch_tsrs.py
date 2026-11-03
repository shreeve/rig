#!/usr/bin/env python3
"""Patch the scratch tsrs copy (ck0/tsrs, 0.18.0) with the same call
counters as patch_trig.py, printed as `CK0 0 <index> <value>` at exit."""
import sys
root = sys.argv[1] + '/crates'

def patch(path, pairs):
    p = f'{root}/{path}'
    s = open(p).read()
    for old, new in pairs:
        n = s.count(old)
        if n != 1:
            sys.exit(f'{path}: {n} matches for {old[:80]!r}')
        s = s.replace(old, new)
    open(p, 'w').write(s)

open(f'{root}/tsrs_checker/src/ck0.rs', 'w').write('''//! CK0 call counters (scratch).
use std::sync::atomic::{AtomicU64, Ordering};
pub static C: [AtomicU64; 100] = [const { AtomicU64::new(0) }; 100];
#[inline(always)]
pub fn add(i: usize, n: u64) {
    C[i].fetch_add(n, Ordering::Relaxed);
}
pub fn dump() {
    for (i, c) in C.iter().enumerate() {
        let v = c.load(Ordering::Relaxed);
        if v != 0 {
            println!("CK0 0 {} {}", i, v);
        }
    }
}
''')
patch('tsrs_checker/src/lib.rs', [("pub mod checker;\n", "pub mod checker;\npub mod ck0;\n")])
patch('tsrs_compiler/src/lib.rs', [("pub use tsrs_checker::sitecount::dump as dump_site_counts;\n",
    "pub use tsrs_checker::sitecount::dump as dump_site_counts;\npub use tsrs_checker::ck0::dump as dump_ck0;\n")])
patch('tsrs_cli/src/main.rs', [("            tsrs_compiler::dump_site_counts();\n            result.status\n",
    "            tsrs_compiler::dump_site_counts();\n            tsrs_compiler::dump_ck0();\n            result.status\n")])

C11 = 'tsrs_checker/src/checker_11.rs'
patch(C11, [
("        let Some(m) = m else {\n            return t;\n        };\n        // `could_contain_type_variables(t)`'s cached answers",
 "        crate::ck0::add(0, 1);\n        let Some(m) = m else {\n            crate::ck0::add(1, 1);\n            return t;\n        };\n        // `could_contain_type_variables(t)`'s cached answers"),
("        if t.alias().is_none() {\n            return t;\n        }\n        self.instantiate_type_with_alias_slow(t, m, alias)\n",
 "        if t.alias().is_none() {\n            crate::ck0::add(2, 1);\n            return t;\n        }\n        self.instantiate_type_with_alias_slow(t, m, alias)\n"),
("                    .any(|&a| self.could_contain_type_variables(a))))\n        {\n            return t;\n        }\n",
 "                    .any(|&a| self.could_contain_type_variables(a))))\n        {\n            crate::ck0::add(2, 1);\n            return t;\n        }\n"),
("        let index = self.find_active_mapper(m);\n        // A mapper that was not active",
 "        let index = self.find_active_mapper(m);\n        crate::ck0::add(6, (match index { Some(i) => self.active_mappers.len() - i, None => self.active_mappers.len() }) as u64);\n        crate::ck0::add(12, self.active_mappers.len() as u64);\n        if alias.is_some() && index.is_some() { crate::ck0::add(7, 1); }\n        // A mapper that was not active"),
("            if let Some(cached_type) = self.active_type_mappers_caches[index].get(&key) {\n                crate::sitecount::hit(\"active mapper cache (instantiateTypeWithAlias)\", \"hit\");\n                return cached_type;\n            }\n            Some(key)\n        } else {\n            self.push_active_mapper(m);\n",
 "            if let Some(cached_type) = self.active_type_mappers_caches[index].get(&key) {\n                crate::sitecount::hit(\"active mapper cache (instantiateTypeWithAlias)\", \"hit\");\n                crate::ck0::add(3, 1);\n                return cached_type;\n            }\n            crate::ck0::add(5, 1);\n            Some(key)\n        } else {\n            crate::ck0::add(4, 1);\n            self.push_active_mapper(m);\n"),
("            Some(key) => {\n                self.active_type_mappers_caches[index.unwrap()].insert(key, result);\n",
 "            Some(key) => {\n                let n = self.active_type_mappers_caches[index.unwrap()].len();\n                crate::ck0::add(8, n as u64);\n                crate::ck0::add(9, u64::from(n >= 16));\n                self.active_type_mappers_caches[index.unwrap()].insert(key, result);\n"),
("        let mut cache = self.active_type_mappers_caches.pop().unwrap();\n",
 "        let mut cache = self.active_type_mappers_caches.pop().unwrap();\n        crate::ck0::add(10, cache.len() as u64);\n        crate::ck0::add(11, u64::from(cache.len() > 16));\n"),
# instantiate_type_worker
("        let flags = t.flags();\n        if flags.intersects(TypeFlags::TypeParameter) {\n            return self.get_mapped_type(t, m);\n        } else if flags.intersects(TypeFlags::Object) {\n            let object_flags = t.object_flags();\n            if object_flags\n                .intersects(ObjectFlags::Reference | ObjectFlags::Anonymous | ObjectFlags::Mapped)\n            {\n                if object_flags.intersects(ObjectFlags::Reference)\n                    && t.as_type_reference().node.get().is_none()\n                {\n",
 "        let flags = t.flags();\n        if flags.intersects(TypeFlags::TypeParameter) {\n            crate::ck0::add(30, 1);\n            return self.get_mapped_type(t, m);\n        } else if flags.intersects(TypeFlags::Object) {\n            let object_flags = t.object_flags();\n            if object_flags\n                .intersects(ObjectFlags::Reference | ObjectFlags::Anonymous | ObjectFlags::Mapped)\n            {\n                if object_flags.intersects(ObjectFlags::Reference)\n                    && t.as_type_reference().node.get().is_none()\n                {\n                    crate::ck0::add(31, 1);\n"),
("                        self.instantiate_types_changed(resolved_type_arguments, m)\n                    else {\n                        return t;\n                    };\n",
 "                        self.instantiate_types_changed(resolved_type_arguments, m)\n                    else {\n                        crate::ck0::add(32, 1);\n                        return t;\n                    };\n"),
("                if object_flags.intersects(ObjectFlags::ReverseMapped) {\n                    return self.instantiate_reverse_mapped_type(t, m);\n                }\n                return self.get_object_type_instantiation(t, Some(m), alias);\n            }\n            return t;\n        } else if flags.intersects(TypeFlags::UnionOrIntersection) {\n            let mut source = t;\n",
 "                if object_flags.intersects(ObjectFlags::ReverseMapped) {\n                    crate::ck0::add(33, 1);\n                    return self.instantiate_reverse_mapped_type(t, m);\n                }\n                crate::ck0::add(34, 1);\n                return self.get_object_type_instantiation(t, Some(m), alias);\n            }\n            crate::ck0::add(43, 1);\n            return t;\n        } else if flags.intersects(TypeFlags::UnionOrIntersection) {\n            crate::ck0::add(35, 1);\n            let mut source = t;\n"),
("            if changed.is_none() && alias.symbol() == t.alias().symbol() {\n                return t;\n            }\n",
 "            if changed.is_none() && alias.symbol() == t.alias().symbol() {\n                crate::ck0::add(36, 1);\n                return t;\n            }\n"),
("        } else if flags.intersects(TypeFlags::Index) {\n            let target = self.instantiate_type(t.target().unwrap(), Some(m));\n",
 "        } else if flags.intersects(TypeFlags::Index) {\n            crate::ck0::add(37, 1);\n            let target = self.instantiate_type(t.target().unwrap(), Some(m));\n"),
("        } else if flags.intersects(TypeFlags::IndexedAccess) {\n            let pending = if alias.is_none() {\n",
 "        } else if flags.intersects(TypeFlags::IndexedAccess) {\n            crate::ck0::add(38, 1);\n            let pending = if alias.is_none() {\n"),
("        } else if flags.intersects(TypeFlags::Conditional) {\n            if self.lazy_cond_mapper {\n",
 "        } else if flags.intersects(TypeFlags::Conditional) {\n            crate::ck0::add(41, 1);\n            if self.lazy_cond_mapper {\n"),
("        } else if flags.intersects(TypeFlags::Substitution) {\n            let new_base_type =\n",
 "        } else if flags.intersects(TypeFlags::Substitution) {\n            crate::ck0::add(42, 1);\n            let new_base_type =\n"),
# get_object_type_instantiation
("        alias: Option<P<TypeAlias>>,\n    ) -> P<Type> {\n        let declaration: P<Node> = if t.object_flags().intersects(ObjectFlags::Reference) {\n",
 "        alias: Option<P<TypeAlias>>,\n    ) -> P<Type> {\n        crate::ck0::add(44, 1);\n        let declaration: P<Node> = if t.object_flags().intersects(ObjectFlags::Reference) {\n"),
("        if type_parameters.is_empty() {\n            return t;\n        }\n        // We are instantiating an anonymous type that has one or more type parameters in scope. Apply the\n        // mapper to the type parameters to produce the effective list of type arguments, and compute the\n        // instantiation cache key from the type IDs of the type arguments.\n        let mut type_arguments = self.free_type_lists.pop().unwrap_or_default();\n        type_arguments.extend(\n",
 "        if type_parameters.is_empty() {\n            crate::ck0::add(45, 1);\n            return t;\n        }\n        crate::ck0::add(49, type_parameters.len() as u64);\n        // We are instantiating an anonymous type that has one or more type parameters in scope. Apply the\n        // mapper to the type parameters to produce the effective list of type arguments, and compute the\n        // instantiation cache key from the type IDs of the type arguments.\n        let mut type_arguments = self.free_type_lists.pop().unwrap_or_default();\n        type_arguments.extend(\n"),
("        let mut result = instantiations.get(&key).or(from_seed);\n        if result.is_none() {\n            let too_complex_before = self.too_complex_reports;\n            let new_alias = new_alias.alias();\n",
 "        let mut result = instantiations.get(&key).or(from_seed);\n        crate::ck0::add(if result.is_none() { 47 } else { 46 }, 1);\n        if result.is_none() {\n            let too_complex_before = self.too_complex_reports;\n            let new_alias = new_alias.alias();\n"),
# conditional
("            let key = get_conditional_type_key(&type_arguments, alias, for_constraint);\n            let mut result = root.instantiations.get(&key);\n",
 "            let key = get_conditional_type_key(&type_arguments, alias, for_constraint);\n            let mut result = root.instantiations.get(&key);\n            crate::ck0::add(52, 1);\n            if result.is_some() { crate::ck0::add(53, 1); }\n"),
# instantiate_types and _changed
("        m: Option<P<TypeMapper>>,\n    ) -> Vec<P<Type>> {\n        self.instantiate_list(types, m, super::checker::Checker::instantiate_type)\n",
 "        m: Option<P<TypeMapper>>,\n    ) -> Vec<P<Type>> {\n        crate::ck0::add(50, 1);\n        crate::ck0::add(51, types.len() as u64);\n        self.instantiate_list(types, m, super::checker::Checker::instantiate_type)\n"),
("        m: P<TypeMapper>,\n    ) -> Option<Vec<P<Type>>> {\n        for (i, &t) in types.iter().enumerate() {\n",
 "        m: P<TypeMapper>,\n    ) -> Option<Vec<P<Type>>> {\n        crate::ck0::add(50, 1);\n        crate::ck0::add(51, types.len() as u64);\n        for (i, &t) in types.iter().enumerate() {\n"),
])

patch('tsrs_checker/src/mapper.rs', [
("    pub fn map(&self, c: &mut Checker, t: P<Type>) -> P<Type> {\n        match self.data() {\n            TypeMapperData::Simple { source, target } => {\n",
 "    pub fn map(&self, c: &mut Checker, t: P<Type>) -> P<Type> {\n        crate::ck0::add(20, 1);\n        match self.data() {\n            TypeMapperData::Simple { source, target } => {\n                crate::ck0::add(21, 1);\n"),
("            TypeMapperData::Array { sources, targets } => {\n                if let Some(result) = sources\n",
 "            TypeMapperData::Array { sources, targets } => {\n                crate::ck0::add(22, 1);\n                crate::ck0::add(29, sources.len() as u64);\n                if let Some(result) = sources\n"),
("            TypeMapperData::ArrayToSingle { sources, target } => {\n                if sources.contains(&t) {\n",
 "            TypeMapperData::ArrayToSingle { sources, target } => {\n                crate::ck0::add(23, 1);\n                if sources.contains(&t) {\n"),
("            TypeMapperData::Deferred { data } => {\n                if let Some(result) = data\n",
 "            TypeMapperData::Deferred { data } => {\n                crate::ck0::add(24, 1);\n                if let Some(result) = data\n"),
("            TypeMapperData::Function { f } => f(c, t),\n            TypeMapperData::Merged { m1, m2 } => {\n                let t1 = m1.map(c, t);\n",
 "            TypeMapperData::Function { f } => {\n                crate::ck0::add(25, 1);\n                f(c, t)\n            }\n            TypeMapperData::Merged { m1, m2 } => {\n                crate::ck0::add(26, 1);\n                let t1 = m1.map(c, t);\n"),
("            TypeMapperData::Composite { m1, m2 } => {\n                let t1 = m1.map(c, t);\n                if t1 != t {\n                    return c.instantiate_type(t1, Some(m2));\n                }\n                m2.map(c, t)\n            }\n            TypeMapperData::Inference { n, fixing } => {\n",
 "            TypeMapperData::Composite { m1, m2 } => {\n                crate::ck0::add(27, 1);\n                let t1 = m1.map(c, t);\n                if t1 != t {\n                    return c.instantiate_type(t1, Some(m2));\n                }\n                m2.map(c, t)\n            }\n            TypeMapperData::Inference { n, fixing } => {\n                crate::ck0::add(28, 1);\n"),
])

patch('tsrs_checker/src/checker_12.rs', [
("        let intf = target.as_interface_type();\n        if let Some(t) = intf.instantiations.get(type_arguments) {\n            return t;\n        }\n",
 "        let intf = target.as_interface_type();\n        crate::ck0::add(54, 1);\n        if let Some(t) = intf.instantiations.get(type_arguments) {\n            crate::ck0::add(55, 1);\n            return t;\n        }\n"),
])
print('patched')
