use std::collections::BTreeSet;

struct CococoirConfig {
    hostname: String,
}

struct CocoUser {
    username: String,
    hashed_password: String,
    // I dont know how we should represent this, because in the nix config its written as:
    // user.<username>.groups = ["wheel"];
    // Eventually decided to go with an is_admin method.
    // I am choosing to represent this as a set, since each element should be unique, and it
    // makes it easier to deal with at runtime. (Note this should serialize and deseralize as an
    // alaphabetical list)
    groups: BTreeSet<String>,
}

impl CocoUser {
    fn is_password_correct(&self, password_attempt: &str) -> bool {
        todo!()
    }
    fn set_password(&mut self, new_password: &str) {
        todo!()
    }
    fn is_admin(&self) -> bool {
        self.groups.contains(&"wheel".to_string())
    }
    fn set_admin(&mut self, admin_flag: bool) {
        if admin_flag {
            self.groups.insert("wheel".to_string());
        } else {
            self.groups.remove(&"wheel".to_string());
        }
    }
}
