//! Import of static Wavefront OBJ files as Roblox FileMesh v1.01.
//!
//! OBJ supports positions, texture coordinates, normals and polygon faces.
//! This importer triangulates polygons and writes one Roblox vertex record
//! per face corner so separate OBJ position/UV/normal indices are preserved.
//! Rigging, skin weights and material libraries are not part of OBJ geometry.

use anyhow::{ensure, Context, Result};
use std::fmt::Write as _;

#[derive(Clone, Copy)]
struct Corner {
    position: usize,
    uv: Option<usize>,
    normal: Option<usize>,
}

fn number(raw: &str, line: usize, what: &str) -> Result<f32> {
    let value: f32 = raw.parse().with_context(|| format!("OBJ line {line}: invalid {what} '{raw}'"))?;
    ensure!(value.is_finite(), "OBJ line {line}: {what} must be finite");
    Ok(value)
}

fn index(raw: &str, len: usize, line: usize, what: &str) -> Result<usize> {
    let value: isize = raw.parse().with_context(|| format!("OBJ line {line}: invalid {what} index '{raw}'"))?;
    ensure!(value != 0, "OBJ line {line}: OBJ indices are one-based; zero is invalid");
    let resolved = if value > 0 { value - 1 } else { len as isize + value };
    ensure!(resolved >= 0 && (resolved as usize) < len, "OBJ line {line}: {what} index {value} is out of range");
    Ok(resolved as usize)
}

fn corner(raw: &str, positions: usize, uvs: usize, normals: usize, line: usize) -> Result<Corner> {
    let mut parts = raw.split('/');
    let position = index(parts.next().unwrap_or(""), positions, line, "position")?;
    let uv = parts.next().filter(|part| !part.is_empty()).map(|part| index(part, uvs, line, "UV")).transpose()?;
    let normal = parts.next().filter(|part| !part.is_empty()).map(|part| index(part, normals, line, "normal")).transpose()?;
    ensure!(parts.next().is_none(), "OBJ line {line}: too many '/' fields in face vertex");
    Ok(Corner { position, uv, normal })
}

fn face_normal(a: [f32; 3], b: [f32; 3], c: [f32; 3]) -> [f32; 3] {
    let (u, v) = (
        [b[0] - a[0], b[1] - a[1], b[2] - a[2]],
        [c[0] - a[0], c[1] - a[1], c[2] - a[2]],
    );
    let cross = [
        u[1] * v[2] - u[2] * v[1],
        u[2] * v[0] - u[0] * v[2],
        u[0] * v[1] - u[1] * v[0],
    ];
    let length = (cross[0] * cross[0] + cross[1] * cross[1] + cross[2] * cross[2]).sqrt();
    if length > 1.0e-12 { [cross[0] / length, cross[1] / length, cross[2] / length] } else { [0.0, 1.0, 0.0] }
}

/// Converts UTF-8 Wavefront OBJ geometry into Roblox's textual FileMesh v1.01.
/// Each face corner gets a separate record to preserve OBJ's independent indices.
pub fn to_roblox_mesh(input: &[u8]) -> Result<Vec<u8>> {
    let text = std::str::from_utf8(input).context("OBJ file must be UTF-8 text")?;
    let (mut positions, mut uvs, mut normals, mut triangles) = (Vec::new(), Vec::new(), Vec::new(), Vec::new());

    for (offset, source) in text.lines().enumerate() {
        let line_no = offset + 1;
        let line = source.split('#').next().unwrap_or("").trim();
        if line.is_empty() { continue; }
        let mut fields = line.split_whitespace();
        match fields.next().unwrap_or("") {
            "v" => {
                let values = fields.take(4).collect::<Vec<_>>();
                ensure!(values.len() >= 3, "OBJ line {line_no}: vertex needs x, y and z");
                positions.push([
                    number(values[0], line_no, "vertex x")?,
                    number(values[1], line_no, "vertex y")?,
                    number(values[2], line_no, "vertex z")?,
                ]);
                ensure!(positions.len() <= 10_000_000, "OBJ has too many vertices");
            }
            "vt" => {
                let values = fields.take(3).collect::<Vec<_>>();
                ensure!(values.len() >= 2, "OBJ line {line_no}: texture coordinate needs u and v");
                uvs.push([number(values[0], line_no, "UV u")?, number(values[1], line_no, "UV v")?]);
                ensure!(uvs.len() <= 10_000_000, "OBJ has too many texture coordinates");
            }
            "vn" => {
                let values = fields.take(3).collect::<Vec<_>>();
                ensure!(values.len() == 3, "OBJ line {line_no}: normal needs x, y and z");
                let n = [number(values[0], line_no, "normal x")?, number(values[1], line_no, "normal y")?, number(values[2], line_no, "normal z")?];
                let length = (n[0] * n[0] + n[1] * n[1] + n[2] * n[2]).sqrt();
                ensure!(length > 1.0e-12, "OBJ line {line_no}: normal cannot be zero");
                normals.push([n[0] / length, n[1] / length, n[2] / length]);
                ensure!(normals.len() <= 10_000_000, "OBJ has too many normals");
            }
            "f" => {
                let corners = fields.map(|part| corner(part, positions.len(), uvs.len(), normals.len(), line_no)).collect::<Result<Vec<_>>>()?;
                ensure!(corners.len() >= 3, "OBJ line {line_no}: face needs at least three vertices");
                for i in 1..corners.len() - 1 {
                    triangles.push([corners[0], corners[i], corners[i + 1]]);
                    ensure!(triangles.len() <= 2_000_000, "OBJ has too many triangles");
                }
            }
            // Object, group, smoothing and material declarations do not alter static geometry.
            _ => {}
        }
    }

    ensure!(!positions.is_empty(), "OBJ contains no vertices");
    ensure!(!triangles.is_empty(), "OBJ contains no faces");
    let mut out = String::with_capacity(triangles.len() * 180 + 32);
    writeln!(&mut out, "version 1.01")?;
    writeln!(&mut out, "{}", triangles.len())?;
    for tri in triangles {
        let a = positions[tri[0].position];
        let b = positions[tri[1].position];
        let c = positions[tri[2].position];
        let flat_normal = face_normal(a, b, c);
        for item in tri {
            let p = positions[item.position];
            let n = item.normal.map_or(flat_normal, |i| normals[i]);
            let uv = item.uv.map_or([0.0, 0.0], |i| uvs[i]);
            // Roblox's FileMesh v1.01 stores the vertical UV coordinate upside down.
            writeln!(
                &mut out,
                "[{},{},{}][{},{},{}][{},{},0]",
                p[0], p[1], p[2], n[0], n[1], n[2], uv[0], 1.0 - uv[1]
            )?;
        }
    }
    Ok(out.into_bytes())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn imports_obj_with_independent_uvs_and_normals() {
        let obj = b"v 0 0 0\nv 1 0 0\nv 0 1 0\nvt 0 0\nvt 1 0\nvt 0 1\nvn 0 0 2\nf 1/1/1 2/2/1 3/3/1\n";
        let converted = to_roblox_mesh(obj).unwrap();
        assert!(converted.starts_with(b"version 1.01\n1\n"));
        let parsed = crate::viewers::parse_mesh(&converted).unwrap();
        assert_eq!(parsed.faces, [[0, 1, 2]]);
        assert_eq!(parsed.positions, [[0.0, 0.0, 0.0], [1.0, 0.0, 0.0], [0.0, 1.0, 0.0]]);
        assert!(String::from_utf8(converted).unwrap().contains("[0,1,0]"));
    }

    #[test]
    fn triangulates_quads_and_supports_negative_indices() {
        let obj = b"v 0 0 0\nv 1 0 0\nv 1 1 0\nv 0 1 0\nf -4 -3 -2 -1\n";
        let converted = to_roblox_mesh(obj).unwrap();
        assert!(converted.starts_with(b"version 1.01\n2\n"));
        let parsed = crate::viewers::parse_mesh(&converted).unwrap();
        assert_eq!(parsed.faces, [[0, 1, 2], [3, 4, 5]]);
        assert_eq!(parsed.positions.len(), 6);
    }

    #[test]
    fn computes_normals_when_obj_has_none() {
        let obj = b"v 0 0 0\nv 1 0 0\nv 0 1 0\nf 1 2 3\n";
        let converted = String::from_utf8(to_roblox_mesh(obj).unwrap()).unwrap();
        assert!(converted.contains("[0,0,1]"));
    }

    #[test]
    fn rejects_bad_obj_indices() {
        let obj = b"v 0 0 0\nv 1 0 0\nv 0 1 0\nf 1 2 4\n";
        assert!(to_roblox_mesh(obj).is_err());
    }
}
