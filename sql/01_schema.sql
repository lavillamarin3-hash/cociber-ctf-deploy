\set ON_ERROR_STOP on
-- Fresh installation only. No application rows, passwords or destructive DDL.
-- Run using psql against cociber_ctf after sql/00_roles.sql.
BEGIN;
SET LOCAL ROLE cociberctf;
SET LOCAL search_path = public, pg_catalog;
DO $guard$
BEGIN
    IF current_database() <> 'cociber_ctf' THEN
        RAISE EXCEPTION 'Expected database cociber_ctf; no schema was created';
    END IF;
    IF EXISTS (
        SELECT 1 FROM pg_catalog.pg_class c
        JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'public'
          AND c.relkind IN ('r', 'p', 'v', 'm', 'S', 'f', 'i', 'I', 'c')
    ) OR EXISTS (
        SELECT 1 FROM pg_catalog.pg_proc p
        JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'public'
    ) OR EXISTS (
        SELECT 1 FROM pg_catalog.pg_type t
        JOIN pg_catalog.pg_namespace n ON n.oid = t.typnamespace
        WHERE n.nspname = 'public'
    ) THEN
        RAISE EXCEPTION 'public is not empty; use a reviewed migration or backup restore';
    END IF;
END
$guard$;

-- Generated from backend/app/models.py; SHA-256: 70d0d9d7af07dcc3e6a103e77b7610fd7879b4ea85496224e26d8f245d93e1d3

-- Compatibility source backend/app/db.py; SHA-256: 3d0302d1ecc3a824c4536d20de8c446c7bcddc6f00acf09d23ffbce480a72813

-- ORM tables: 19

CREATE TABLE laboratories (
	id SERIAL NOT NULL,
	code VARCHAR(64),
	name VARCHAR(120) NOT NULL,
	description VARCHAR(300) NOT NULL,
	segment VARCHAR(64) NOT NULL,
	status VARCHAR(32) NOT NULL,
	created_at TIMESTAMP WITH TIME ZONE DEFAULT now() NOT NULL,
	PRIMARY KEY (id)
);

CREATE UNIQUE INDEX ix_laboratories_code ON laboratories (code);

CREATE UNIQUE INDEX ix_laboratories_name ON laboratories (name);

CREATE INDEX ix_laboratories_status ON laboratories (status);

CREATE TABLE roles (
	id SERIAL NOT NULL,
	name VARCHAR(32) NOT NULL,
	description VARCHAR(160) NOT NULL,
	PRIMARY KEY (id),
	UNIQUE (name)
);

CREATE TABLE users (
	id SERIAL NOT NULL,
	username VARCHAR(64) NOT NULL,
	email VARCHAR(255),
	password_hash VARCHAR(512) NOT NULL,
	role VARCHAR(32) NOT NULL,
	full_name VARCHAR(160),
	organization VARCHAR(160),
	user_function VARCHAR(80),
	is_active BOOLEAN NOT NULL,
	created_at TIMESTAMP WITH TIME ZONE DEFAULT now() NOT NULL,
	PRIMARY KEY (id),
	UNIQUE (email)
);

CREATE INDEX ix_users_role ON users (role);

CREATE UNIQUE INDEX ix_users_username ON users (username);

CREATE TABLE audit_events (
	id SERIAL NOT NULL,
	actor_id INTEGER,
	action VARCHAR(120) NOT NULL,
	entity_type VARCHAR(64) NOT NULL,
	entity_id VARCHAR(64) NOT NULL,
	details JSON NOT NULL,
	created_at TIMESTAMP WITH TIME ZONE DEFAULT now() NOT NULL,
	PRIMARY KEY (id),
	FOREIGN KEY(actor_id) REFERENCES users (id)
);

CREATE INDEX ix_audit_events_action ON audit_events (action);

CREATE INDEX ix_audit_events_actor_id ON audit_events (actor_id);

CREATE INDEX ix_audit_events_created_at ON audit_events (created_at);

CREATE TABLE challenges (
	id SERIAL NOT NULL,
	code VARCHAR(64) NOT NULL,
	name VARCHAR(160) NOT NULL,
	description TEXT NOT NULL,
	instructions TEXT NOT NULL,
	difficulty VARCHAR(16) NOT NULL,
	category VARCHAR(48) NOT NULL,
	scenario VARCHAR(64),
	mitre_technique VARCHAR(64) NOT NULL,
	asset_references JSON NOT NULL,
	points INTEGER NOT NULL,
	learning_policy JSON,
	is_published BOOLEAN NOT NULL,
	created_by INTEGER,
	created_at TIMESTAMP WITH TIME ZONE DEFAULT now() NOT NULL,
	PRIMARY KEY (id),
	FOREIGN KEY(created_by) REFERENCES users (id)
);

CREATE INDEX ix_challenges_category ON challenges (category);

CREATE UNIQUE INDEX ix_challenges_code ON challenges (code);

CREATE INDEX ix_challenges_difficulty ON challenges (difficulty);

CREATE INDEX ix_challenges_mitre_technique ON challenges (mitre_technique);

CREATE INDEX ix_challenges_scenario ON challenges (scenario);

CREATE TABLE reset_operations (
	id SERIAL NOT NULL,
	laboratory_id INTEGER NOT NULL,
	requested_by INTEGER,
	scope VARCHAR(32) NOT NULL,
	reason VARCHAR(300) NOT NULL,
	status VARCHAR(32) NOT NULL,
	started_at TIMESTAMP WITH TIME ZONE,
	completed_at TIMESTAMP WITH TIME ZONE,
	message VARCHAR(500) NOT NULL,
	created_at TIMESTAMP WITH TIME ZONE DEFAULT now() NOT NULL,
	PRIMARY KEY (id),
	FOREIGN KEY(laboratory_id) REFERENCES laboratories (id) ON DELETE CASCADE,
	FOREIGN KEY(requested_by) REFERENCES users (id)
);

CREATE INDEX ix_reset_operations_created_at ON reset_operations (created_at);

CREATE INDEX ix_reset_operations_laboratory_id ON reset_operations (laboratory_id);

CREATE INDEX ix_reset_operations_requested_by ON reset_operations (requested_by);

CREATE INDEX ix_reset_operations_status ON reset_operations (status);

CREATE TABLE student_groups (
	id SERIAL NOT NULL,
	name VARCHAR(120) NOT NULL,
	code VARCHAR(64) NOT NULL,
	description VARCHAR(300) NOT NULL,
	is_active BOOLEAN NOT NULL,
	guacamole_group_identifier VARCHAR(128),
	created_by INTEGER,
	created_at TIMESTAMP WITH TIME ZONE DEFAULT now() NOT NULL,
	PRIMARY KEY (id),
	CONSTRAINT uq_student_group_name UNIQUE (name),
	UNIQUE (guacamole_group_identifier),
	FOREIGN KEY(created_by) REFERENCES users (id)
);

CREATE UNIQUE INDEX ix_student_groups_code ON student_groups (code);

CREATE INDEX ix_student_groups_name ON student_groups (name);

CREATE TABLE vm_assets (
	id SERIAL NOT NULL,
	laboratory_id INTEGER NOT NULL,
	name VARCHAR(120) NOT NULL,
	os VARCHAR(120) NOT NULL,
	ip_address VARCHAR(64),
	vlan VARCHAR(32) NOT NULL,
	role VARCHAR(120) NOT NULL,
	network_role VARCHAR(64) NOT NULL,
	subnet VARCHAR(64) NOT NULL,
	profile VARCHAR(32) NOT NULL,
	baseline VARCHAR(160),
	nutanix_vm_id VARCHAR(160),
	guacamole_connection_id VARCHAR(160),
	status VARCHAR(32) NOT NULL,
	created_at TIMESTAMP WITH TIME ZONE DEFAULT now() NOT NULL,
	PRIMARY KEY (id),
	FOREIGN KEY(laboratory_id) REFERENCES laboratories (id) ON DELETE CASCADE
);

CREATE INDEX ix_vm_assets_guacamole_connection_id ON vm_assets (guacamole_connection_id);

CREATE INDEX ix_vm_assets_laboratory_id ON vm_assets (laboratory_id);

CREATE INDEX ix_vm_assets_status ON vm_assets (status);

CREATE TABLE challenge_completions (
	id SERIAL NOT NULL,
	user_id INTEGER NOT NULL,
	challenge_id INTEGER NOT NULL,
	completed_at TIMESTAMP WITH TIME ZONE DEFAULT now() NOT NULL,
	awarded_points INTEGER NOT NULL,
	PRIMARY KEY (id),
	CONSTRAINT uq_completion_user_challenge UNIQUE (user_id, challenge_id),
	FOREIGN KEY(user_id) REFERENCES users (id),
	FOREIGN KEY(challenge_id) REFERENCES challenges (id)
);

CREATE INDEX ix_challenge_completions_challenge_id ON challenge_completions (challenge_id);

CREATE INDEX ix_challenge_completions_user_id ON challenge_completions (user_id);

CREATE TABLE challenge_flags (
	id SERIAL NOT NULL,
	challenge_id INTEGER NOT NULL,
	label VARCHAR(120) NOT NULL,
	flag_hash VARCHAR(512),
	validator VARCHAR(32) NOT NULL,
	mode VARCHAR(16) NOT NULL,
	template VARCHAR(512),
	flag_order INTEGER NOT NULL,
	is_active BOOLEAN NOT NULL,
	PRIMARY KEY (id),
	FOREIGN KEY(challenge_id) REFERENCES challenges (id) ON DELETE CASCADE
);

CREATE INDEX ix_challenge_flags_challenge_id ON challenge_flags (challenge_id);

CREATE TABLE challenge_group_assignments (
	id SERIAL NOT NULL,
	challenge_id INTEGER NOT NULL,
	group_id INTEGER NOT NULL,
	created_by INTEGER,
	created_at TIMESTAMP WITH TIME ZONE DEFAULT now() NOT NULL,
	PRIMARY KEY (id),
	CONSTRAINT uq_challenge_group UNIQUE (challenge_id, group_id),
	FOREIGN KEY(challenge_id) REFERENCES challenges (id) ON DELETE CASCADE,
	FOREIGN KEY(group_id) REFERENCES student_groups (id) ON DELETE CASCADE,
	FOREIGN KEY(created_by) REFERENCES users (id)
);

CREATE INDEX ix_challenge_group_assignments_challenge_id ON challenge_group_assignments (challenge_id);

CREATE INDEX ix_challenge_group_assignments_group_id ON challenge_group_assignments (group_id);

CREATE TABLE challenge_runs (
	id SERIAL NOT NULL,
	user_id INTEGER NOT NULL,
	challenge_id INTEGER NOT NULL,
	status VARCHAR(32) NOT NULL,
	workspace_strategy VARCHAR(32) NOT NULL,
	started_at TIMESTAMP WITH TIME ZONE DEFAULT now() NOT NULL,
	expires_at TIMESTAMP WITH TIME ZONE NOT NULL,
	closed_at TIMESTAMP WITH TIME ZONE,
	PRIMARY KEY (id),
	FOREIGN KEY(user_id) REFERENCES users (id),
	FOREIGN KEY(challenge_id) REFERENCES challenges (id)
);

CREATE INDEX ix_challenge_runs_challenge_id ON challenge_runs (challenge_id);

CREATE INDEX ix_challenge_runs_status ON challenge_runs (status);

CREATE INDEX ix_challenge_runs_user_id ON challenge_runs (user_id);

CREATE TABLE group_memberships (
	id SERIAL NOT NULL,
	group_id INTEGER NOT NULL,
	user_id INTEGER NOT NULL,
	created_at TIMESTAMP WITH TIME ZONE DEFAULT now() NOT NULL,
	PRIMARY KEY (id),
	CONSTRAINT uq_group_member UNIQUE (group_id, user_id),
	FOREIGN KEY(group_id) REFERENCES student_groups (id) ON DELETE CASCADE,
	FOREIGN KEY(user_id) REFERENCES users (id) ON DELETE CASCADE
);

CREATE INDEX ix_group_memberships_group_id ON group_memberships (group_id);

CREATE INDEX ix_group_memberships_user_id ON group_memberships (user_id);

CREATE TABLE challenge_instances (
	id SERIAL NOT NULL,
	challenge_id INTEGER NOT NULL,
	vm_asset_id INTEGER NOT NULL,
	run_id INTEGER,
	user_id INTEGER,
	state VARCHAR(20) NOT NULL,
	ip_address VARCHAR(64),
	guacamole_connection_id VARCHAR(160),
	guacamole_access_granted BOOLEAN NOT NULL,
	guacamole_access_preexisting BOOLEAN NOT NULL,
	reserved_at TIMESTAMP WITH TIME ZONE,
	expires_at TIMESTAMP WITH TIME ZONE,
	last_error VARCHAR(500),
	created_at TIMESTAMP WITH TIME ZONE DEFAULT now() NOT NULL,
	updated_at TIMESTAMP WITH TIME ZONE DEFAULT now() NOT NULL,
	PRIMARY KEY (id),
	CONSTRAINT uq_challenge_instance_run UNIQUE (run_id),
	FOREIGN KEY(challenge_id) REFERENCES challenges (id) ON DELETE CASCADE,
	FOREIGN KEY(vm_asset_id) REFERENCES vm_assets (id) ON DELETE CASCADE,
	FOREIGN KEY(run_id) REFERENCES challenge_runs (id) ON DELETE SET NULL,
	FOREIGN KEY(user_id) REFERENCES users (id) ON DELETE SET NULL
);

CREATE INDEX ix_challenge_instances_challenge_id ON challenge_instances (challenge_id);

CREATE INDEX ix_challenge_instances_challenge_state ON challenge_instances (challenge_id, state);

CREATE INDEX ix_challenge_instances_run_id ON challenge_instances (run_id);

CREATE INDEX ix_challenge_instances_state ON challenge_instances (state);

CREATE INDEX ix_challenge_instances_user_id ON challenge_instances (user_id);

CREATE INDEX ix_challenge_instances_vm_asset_id ON challenge_instances (vm_asset_id);

CREATE TABLE challenge_learning_progress (
	id SERIAL NOT NULL,
	user_id INTEGER NOT NULL,
	challenge_id INTEGER NOT NULL,
	first_run_id INTEGER,
	policy_version INTEGER NOT NULL,
	policy_snapshot JSON,
	base_points INTEGER NOT NULL,
	deadline TIMESTAMP WITH TIME ZONE NOT NULL,
	solution_revealed_at TIMESTAMP WITH TIME ZONE,
	is_assisted BOOLEAN NOT NULL,
	created_at TIMESTAMP WITH TIME ZONE DEFAULT now() NOT NULL,
	PRIMARY KEY (id),
	CONSTRAINT uq_learning_user_challenge UNIQUE (user_id, challenge_id),
	CONSTRAINT ck_learning_base_points CHECK (base_points >= 0),
	FOREIGN KEY(user_id) REFERENCES users (id) ON DELETE CASCADE,
	FOREIGN KEY(challenge_id) REFERENCES challenges (id) ON DELETE CASCADE,
	FOREIGN KEY(first_run_id) REFERENCES challenge_runs (id) ON DELETE SET NULL
);

CREATE INDEX ix_challenge_learning_progress_challenge_id ON challenge_learning_progress (challenge_id);

CREATE INDEX ix_challenge_learning_progress_user_id ON challenge_learning_progress (user_id);

CREATE TABLE challenge_run_flags (
	id SERIAL NOT NULL,
	run_id INTEGER NOT NULL,
	flag_id INTEGER NOT NULL,
	flag_hash VARCHAR(512) NOT NULL,
	fingerprint VARCHAR(64) NOT NULL,
	created_at TIMESTAMP WITH TIME ZONE DEFAULT now() NOT NULL,
	PRIMARY KEY (id),
	CONSTRAINT uq_run_flag UNIQUE (run_id, flag_id),
	FOREIGN KEY(run_id) REFERENCES challenge_runs (id) ON DELETE CASCADE,
	FOREIGN KEY(flag_id) REFERENCES challenge_flags (id) ON DELETE CASCADE
);

CREATE INDEX ix_challenge_run_flags_fingerprint ON challenge_run_flags (fingerprint);

CREATE INDEX ix_challenge_run_flags_flag_id ON challenge_run_flags (flag_id);

CREATE INDEX ix_challenge_run_flags_run_id ON challenge_run_flags (run_id);

CREATE TABLE remote_access_assignments (
	id SERIAL NOT NULL,
	run_id INTEGER NOT NULL,
	provider VARCHAR(32) NOT NULL,
	external_reference VARCHAR(160) NOT NULL,
	launch_url VARCHAR(1024) NOT NULL,
	status VARCHAR(32) NOT NULL,
	expires_at TIMESTAMP WITH TIME ZONE NOT NULL,
	PRIMARY KEY (id),
	UNIQUE (run_id),
	FOREIGN KEY(run_id) REFERENCES challenge_runs (id) ON DELETE CASCADE,
	UNIQUE (external_reference)
);

CREATE TABLE submissions (
	id SERIAL NOT NULL,
	user_id INTEGER NOT NULL,
	challenge_id INTEGER NOT NULL,
	flag_id INTEGER,
	submitted_value_hmac VARCHAR(64) NOT NULL,
	is_correct BOOLEAN NOT NULL,
	submitted_at TIMESTAMP WITH TIME ZONE DEFAULT now() NOT NULL,
	PRIMARY KEY (id),
	FOREIGN KEY(user_id) REFERENCES users (id),
	FOREIGN KEY(challenge_id) REFERENCES challenges (id),
	FOREIGN KEY(flag_id) REFERENCES challenge_flags (id)
);

CREATE INDEX ix_submissions_challenge_id ON submissions (challenge_id);

CREATE INDEX ix_submissions_submitted_at ON submissions (submitted_at);

CREATE INDEX ix_submissions_user_id ON submissions (user_id);

CREATE TABLE challenge_hint_reveals (
	id SERIAL NOT NULL,
	progress_id INTEGER NOT NULL,
	run_id INTEGER,
	hint_id INTEGER NOT NULL,
	penalty_percent INTEGER NOT NULL,
	revealed_at TIMESTAMP WITH TIME ZONE DEFAULT now() NOT NULL,
	PRIMARY KEY (id),
	CONSTRAINT uq_learning_hint_reveal UNIQUE (progress_id, hint_id),
	CONSTRAINT ck_learning_hint_id CHECK (hint_id >= 1 AND hint_id <= 3),
	CONSTRAINT ck_learning_hint_penalty CHECK (penalty_percent >= 0 AND penalty_percent <= 100),
	FOREIGN KEY(progress_id) REFERENCES challenge_learning_progress (id) ON DELETE CASCADE,
	FOREIGN KEY(run_id) REFERENCES challenge_runs (id) ON DELETE SET NULL
);

CREATE INDEX ix_challenge_hint_reveals_progress_id ON challenge_hint_reveals (progress_id);

CREATE INDEX ix_challenge_hint_reveals_run_id ON challenge_hint_reveals (run_id);

-- Additional indexes applied by app.db.create_schema on a fresh installation.

CREATE UNIQUE INDEX uq_laboratories_code ON laboratories (code) WHERE code IS NOT NULL;

CREATE UNIQUE INDEX uq_student_groups_guacamole_identifier ON student_groups(guacamole_group_identifier) WHERE guacamole_group_identifier IS NOT NULL;

COMMIT;
