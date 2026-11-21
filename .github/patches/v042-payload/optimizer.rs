//! Lightweight, read-only machine diagnostics and Roblox performance advice.

#[derive(Clone, Debug)]
pub struct Snapshot {
    pub logical_cores: usize,
    pub total_memory_gib: Option<f32>,
    pub roblox_running: bool,
}

pub fn snapshot(roblox_running: bool) -> Snapshot {
    Snapshot { logical_cores: std::thread::available_parallelism().map(usize::from).unwrap_or(1), total_memory_gib: total_memory_gib(), roblox_running }
}

#[cfg(target_os = "windows")]
fn total_memory_gib() -> Option<f32> {
    #[repr(C)]
    struct MemoryStatus {
        length: u32,
        memory_load: u32,
        total_phys: u64,
        avail_phys: u64,
        total_page: u64,
        avail_page: u64,
        total_virtual: u64,
        avail_virtual: u64,
        avail_extended: u64,
    }
    #[link(name = "kernel32")]
    unsafe extern "system" {
        fn GlobalMemoryStatusEx(status: *mut MemoryStatus) -> i32;
    }
    let mut status = MemoryStatus {
        length: std::mem::size_of::<MemoryStatus>() as u32,
        memory_load: 0,
        total_phys: 0,
        avail_phys: 0,
        total_page: 0,
        avail_page: 0,
        total_virtual: 0,
        avail_virtual: 0,
        avail_extended: 0,
    };
    // SAFETY: Windows fills the documented MEMORYSTATUSEX structure.
    if unsafe { GlobalMemoryStatusEx(&mut status) } == 0 { return None; }
    Some(status.total_phys as f32 / 1_073_741_824.0)
}

#[cfg(target_os = "linux")]
fn total_memory_gib() -> Option<f32> {
    let text = std::fs::read_to_string("/proc/meminfo").ok()?;
    let value = text.lines().find(|line| line.starts_with("MemTotal:"))?.split_whitespace().nth(1)?.parse::<u64>().ok()?;
    Some(value as f32 / 1_048_576.0)
}

#[cfg(not(any(target_os = "windows", target_os = "linux")))]
fn total_memory_gib() -> Option<f32> { None }

pub fn recommended_graphics_level(snapshot: &Snapshot) -> u8 {
    let memory = snapshot.total_memory_gib.unwrap_or(8.0);
    if snapshot.logical_cores <= 4 || memory <= 4.0 { 2 }
    else if snapshot.logical_cores <= 6 || memory <= 8.0 { 4 }
    else if snapshot.logical_cores <= 8 { 6 }
    else { 8 }
}

pub fn recommendation(snapshot: &Snapshot) -> &'static str {
    let memory = snapshot.total_memory_gib.unwrap_or(8.0);
    if snapshot.logical_cores <= 4 || memory <= 4.0 {
        "Low-end profile: use manual graphics quality 1–3 and close heavy background apps."
    } else if snapshot.logical_cores <= 6 || memory <= 8.0 {
        "Balanced profile: start around graphics quality 4–5 and increase only while frame pacing stays stable."
    } else {
        "Balanced-to-high profile: start around graphics quality 6–8; monitor temperatures and frame pacing during long sessions."
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn recommendation_is_always_a_valid_manual_graphics_level() {
        for snapshot in [
            Snapshot { logical_cores: 2, total_memory_gib: Some(4.0), roblox_running: false },
            Snapshot { logical_cores: 6, total_memory_gib: Some(8.0), roblox_running: true },
            Snapshot { logical_cores: 16, total_memory_gib: Some(32.0), roblox_running: true },
        ] {
            assert!((1..=10).contains(&recommended_graphics_level(&snapshot)));
            assert!(!recommendation(&snapshot).is_empty());
        }
    }
}
