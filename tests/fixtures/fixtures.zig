//! Test fixtures, embedded so tests need no working directory.
pub const postman_v21 = @embedFile("postman_v21.json");
pub const postman_env = @embedFile("postman_env.json");
