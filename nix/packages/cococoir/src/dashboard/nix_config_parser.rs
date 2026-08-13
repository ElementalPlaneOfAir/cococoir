use std::collections::{BTreeMap, BTreeSet};

struct CococoirConfig {
    hostname: String,
    root_domain: String,
    services_enabled: BTreeMap<CococoirServiceConfig, bool>,
    users: BTreeMap<String, CocoUser>,
    extra_config: String,
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
impl Ord for CocoUser {
    fn cmp(&self, other: &Self) -> std::cmp::Ordering {
        self.username.cmp(&other.username)
    }
}

struct CococoirServiceConfig {
    service_nixname: &'static str,
    service_name: &'static str,
    service_description: &'static str,
}

const SERVICE_LIST: &[CococoirServiceConfig] = &[
    CococoirServiceConfig {
        service_nixname: "jellyfin",
        service_name: "Jellyfin",
        service_description: "Its netflix but for your own movies!",
    },
    CococoirServiceConfig {
        service_nixname: "cryptpad",
        service_name: "Cryptpad",
        service_description: "It's like google docs, but fully self encrypted.",
    },
    CococoirServiceConfig {
        service_nixname: "vaultwarden",
        service_name: "Vaultwarden",
        service_description: "Self Hosted, fully encrypted password manager.",
    },
];

impl Ord for CococoirServiceConfig {
    fn cmp(&self, other: &Self) -> std::cmp::Ordering {
        self.service_name.cmp(other.service_name)
    }
}

impl CocoUser {
    // These are going to require bcrypt or some other mechanism
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
