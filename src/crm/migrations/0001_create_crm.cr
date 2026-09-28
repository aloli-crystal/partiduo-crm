# SPDX-License-Identifier: AGPL-3.0-or-later

# Tables de l'extension CRM (ADR-009) et valeurs initiales : étapes du
# pipeline (Découverte 10 %, Qualification 25 %, Proposition 50 %,
# Négociation 75 %, Gagnée 100 %, Perdue 0 %), motifs de perte et origines.
#
# Intégrité en base : natures, bases légales, genres d'activité et de
# document contrôlés ; probabilités de 0 à 100 ; une seule étape « Gagnée »
# (100 %) et une seule « Perdue » (0 %) ; montant positif ou nul ; une
# activité faite est datée ; une activité est rattachée à une
# organisation, un contact ou une opportunité ; historique des étapes en
# ajout seul. Les liens vers une fiche du cœur (`card_id`) et vers un
# document de la Facturation (`document_id`) sont des identifiants lus par
# le contrat, sans clé étrangère (D-CRM-003).
class Migration::Crm::V0001 < Marten::Migration
  depends_on :auth, "0001_create_auth_user_table"

  CONSTRAINTS = [
    {<<-SQL, "SELECT 1"},
      ALTER TABLE crm_stage
        ADD CONSTRAINT crm_stage_kind_check CHECK (kind IN ('open', 'won', 'lost')),
        ADD CONSTRAINT crm_stage_probability_check CHECK (probability BETWEEN 0 AND 100),
        ADD CONSTRAINT crm_stage_closing_check CHECK ((kind <> 'won' OR probability = 100) AND (kind <> 'lost' OR probability = 0)),
        ADD CONSTRAINT crm_stage_closing_active_check CHECK (kind = 'open' OR active)
      SQL
    {"CREATE UNIQUE INDEX crm_stage_closing_unique ON crm_stage (kind) WHERE kind IN ('won', 'lost')",
     "DROP INDEX IF EXISTS crm_stage_closing_unique"},
    {"CREATE UNIQUE INDEX crm_stage_code_unique ON crm_stage (code) WHERE code <> ''", "DROP INDEX IF EXISTS crm_stage_code_unique"},
    {"CREATE UNIQUE INDEX crm_loss_reason_code_unique ON crm_loss_reason (code) WHERE code <> ''",
     "DROP INDEX IF EXISTS crm_loss_reason_code_unique"},
    {"CREATE UNIQUE INDEX crm_source_code_unique ON crm_source (code) WHERE code <> ''", "DROP INDEX IF EXISTS crm_source_code_unique"},
    {<<-SQL, "SELECT 1"},
      ALTER TABLE crm_organization
        ADD CONSTRAINT crm_organization_nature_check CHECK (nature IN ('business', 'individual', 'public')),
        ADD CONSTRAINT crm_organization_name_check CHECK (btrim(name) <> ''),
        ADD CONSTRAINT crm_organization_source_fk FOREIGN KEY (source_id) REFERENCES crm_source (id),
        ADD CONSTRAINT crm_organization_owner_fk FOREIGN KEY (owner_id) REFERENCES auth_user (id)
      SQL
    {<<-SQL, "SELECT 1"},
      ALTER TABLE crm_contact
        ADD CONSTRAINT crm_contact_legal_basis_check CHECK (legal_basis IN ('', 'legitimate_interest', 'consent', 'contract')),
        ADD CONSTRAINT crm_contact_civility_check CHECK (civility IN ('', 'mr', 'ms', 'mx')),
        ADD CONSTRAINT crm_contact_name_check CHECK (btrim(last_name) <> ''),
        ADD CONSTRAINT crm_contact_organization_fk FOREIGN KEY (organization_id) REFERENCES crm_organization (id),
        ADD CONSTRAINT crm_contact_source_fk FOREIGN KEY (source_id) REFERENCES crm_source (id)
      SQL
    {<<-SQL, "SELECT 1"},
      ALTER TABLE crm_opportunity
        ADD CONSTRAINT crm_opportunity_amount_check CHECK (amount >= 0),
        ADD CONSTRAINT crm_opportunity_probability_check CHECK (probability BETWEEN 0 AND 100),
        ADD CONSTRAINT crm_opportunity_title_check CHECK (btrim(title) <> ''),
        ADD CONSTRAINT crm_opportunity_organization_fk FOREIGN KEY (organization_id) REFERENCES crm_organization (id),
        ADD CONSTRAINT crm_opportunity_contact_fk FOREIGN KEY (contact_id) REFERENCES crm_contact (id),
        ADD CONSTRAINT crm_opportunity_stage_fk FOREIGN KEY (stage_id) REFERENCES crm_stage (id),
        ADD CONSTRAINT crm_opportunity_source_fk FOREIGN KEY (source_id) REFERENCES crm_source (id),
        ADD CONSTRAINT crm_opportunity_loss_reason_fk FOREIGN KEY (loss_reason_id) REFERENCES crm_loss_reason (id),
        ADD CONSTRAINT crm_opportunity_owner_fk FOREIGN KEY (owner_id) REFERENCES auth_user (id)
      SQL
    {<<-SQL, "SELECT 1"},
      ALTER TABLE crm_stage_change
        ADD CONSTRAINT crm_stage_change_opportunity_fk FOREIGN KEY (opportunity_id) REFERENCES crm_opportunity (id),
        ADD CONSTRAINT crm_stage_change_from_fk FOREIGN KEY (from_stage_id) REFERENCES crm_stage (id),
        ADD CONSTRAINT crm_stage_change_to_fk FOREIGN KEY (to_stage_id) REFERENCES crm_stage (id),
        ADD CONSTRAINT crm_stage_change_cause_check CHECK (cause IN ('', 'created', 'quote_created', 'quote_accepted'))
      SQL
    {<<-SQL, "DROP FUNCTION IF EXISTS crm_stage_change_guard() CASCADE"},
      CREATE FUNCTION crm_stage_change_guard() RETURNS trigger AS $$
      BEGIN
        RAISE EXCEPTION 'crm: historique des étapes en ajout seul (opportunité %)', OLD.opportunity_id;
      END;
      $$ LANGUAGE plpgsql
      SQL
    {"CREATE TRIGGER crm_stage_change_guard BEFORE UPDATE OR DELETE ON crm_stage_change " \
     "FOR EACH ROW EXECUTE FUNCTION crm_stage_change_guard()", "SELECT 1"},
    {<<-SQL, "SELECT 1"},
      ALTER TABLE crm_document_link
        ADD CONSTRAINT crm_document_link_kind_check CHECK (kind IN ('quote', 'invoice')),
        ADD CONSTRAINT crm_document_link_opportunity_fk FOREIGN KEY (opportunity_id) REFERENCES crm_opportunity (id)
      SQL
    {<<-SQL, "SELECT 1"},
      ALTER TABLE crm_activity
        ADD CONSTRAINT crm_activity_kind_check CHECK (kind IN ('call', 'meeting', 'email', 'task', 'note')),
        ADD CONSTRAINT crm_activity_subject_check CHECK (btrim(subject) <> ''),
        ADD CONSTRAINT crm_activity_duration_check CHECK (duration_minutes IS NULL OR duration_minutes BETWEEN 0 AND 14400),
        ADD CONSTRAINT crm_activity_target_check CHECK (organization_id IS NOT NULL OR contact_id IS NOT NULL OR opportunity_id IS NOT NULL),
        ADD CONSTRAINT crm_activity_done_check CHECK (done = (done_at IS NOT NULL)),
        ADD CONSTRAINT crm_activity_organization_fk FOREIGN KEY (organization_id) REFERENCES crm_organization (id),
        ADD CONSTRAINT crm_activity_contact_fk FOREIGN KEY (contact_id) REFERENCES crm_contact (id),
        ADD CONSTRAINT crm_activity_opportunity_fk FOREIGN KEY (opportunity_id) REFERENCES crm_opportunity (id),
        ADD CONSTRAINT crm_activity_owner_fk FOREIGN KEY (owner_id) REFERENCES auth_user (id)
      SQL
    # Valeurs initiales (ADR-009 D3) : libellés traduits tant que `name` est vide.
    {<<-SQL, "DELETE FROM crm_stage"},
      INSERT INTO crm_stage (code, name, position, probability, kind, active, created_at, updated_at) VALUES
        ('discovery', '', 10, 10, 'open', TRUE, now(), now()),
        ('qualification', '', 20, 25, 'open', TRUE, now(), now()),
        ('proposal', '', 30, 50, 'open', TRUE, now(), now()),
        ('negotiation', '', 40, 75, 'open', TRUE, now(), now()),
        ('won', '', 1000, 100, 'won', TRUE, now(), now()),
        ('lost', '', 1010, 0, 'lost', TRUE, now(), now())
      SQL
    {<<-SQL, "DELETE FROM crm_loss_reason"},
      INSERT INTO crm_loss_reason (code, name, position, active, created_at, updated_at) VALUES
        ('price', '', 10, TRUE, now(), now()),
        ('competitor', '', 20, TRUE, now(), now()),
        ('no_budget', '', 30, TRUE, now(), now()),
        ('no_decision', '', 40, TRUE, now(), now()),
        ('timing', '', 50, TRUE, now(), now()),
        ('other', '', 60, TRUE, now(), now())
      SQL
    {<<-SQL, "DELETE FROM crm_source"},
      INSERT INTO crm_source (code, name, position, active, created_at, updated_at) VALUES
        ('fair', '', 10, TRUE, now(), now()),
        ('website', '', 20, TRUE, now(), now()),
        ('referral', '', 30, TRUE, now(), now()),
        ('prospecting', '', 40, TRUE, now(), now()),
        ('network', '', 50, TRUE, now(), now()),
        ('other', '', 60, TRUE, now(), now())
      SQL
  ]

  def plan
    create_table :crm_stage do
      column :id, :big_int, primary_key: true, auto: true
      column :code, :string, max_size: 32, default: ""
      column :name, :string, max_size: 100, default: ""
      column :position, :int, default: 0
      column :probability, :int, default: 0
      column :kind, :string, max_size: 8, default: "open"
      column :active, :bool, default: true
      column :created_at, :date_time
      column :updated_at, :date_time
    end

    create_table :crm_loss_reason do
      column :id, :big_int, primary_key: true, auto: true
      column :code, :string, max_size: 32, default: ""
      column :name, :string, max_size: 100, default: ""
      column :position, :int, default: 0
      column :active, :bool, default: true
      column :created_at, :date_time
      column :updated_at, :date_time
    end

    create_table :crm_source do
      column :id, :big_int, primary_key: true, auto: true
      column :code, :string, max_size: 32, default: ""
      column :name, :string, max_size: 100, default: ""
      column :position, :int, default: 0
      column :active, :bool, default: true
      column :created_at, :date_time
      column :updated_at, :date_time
    end

    create_table :crm_organization do
      column :id, :big_int, primary_key: true, auto: true
      column :name, :string, max_size: 200
      column :nature, :string, max_size: 16, default: "business"
      column :siren, :string, max_size: 9, default: ""
      column :vat_number, :string, max_size: 32, default: ""
      column :email, :string, max_size: 254, default: ""
      column :phone, :string, max_size: 32, default: ""
      column :website, :string, max_size: 200, default: ""
      column :line1, :string, max_size: 200, default: ""
      column :postcode, :string, max_size: 16, default: ""
      column :city, :string, max_size: 100, default: ""
      column :country_code, :string, max_size: 2, default: ""
      column :card_id, :big_int, null: true, unique: true
      column :source_id, :big_int, null: true
      column :owner_id, :big_int, null: true
      column :notes, :text, default: ""
      column :created_by_id, :big_int, null: true
      column :created_at, :date_time
      column :updated_at, :date_time
    end

    create_table :crm_contact do
      column :id, :big_int, primary_key: true, auto: true
      column :organization_id, :big_int, null: true, index: true
      column :civility, :string, max_size: 8, default: ""
      column :first_name, :string, max_size: 100, default: ""
      column :last_name, :string, max_size: 100
      column :job_title, :string, max_size: 100, default: ""
      column :email, :string, max_size: 254, default: ""
      column :phone, :string, max_size: 32, default: ""
      column :mobile, :string, max_size: 32, default: ""
      column :source_id, :big_int, null: true
      column :legal_basis, :string, max_size: 24, default: ""
      column :legal_basis_on, :date, null: true
      column :opposed_at, :date_time, null: true
      column :opposition_note, :text, default: ""
      column :notes, :text, default: ""
      column :created_at, :date_time
      column :updated_at, :date_time
    end

    create_table :crm_opportunity do
      column :id, :big_int, primary_key: true, auto: true
      column :title, :string, max_size: 200
      column :organization_id, :big_int, index: true
      column :contact_id, :big_int, null: true, index: true
      column :amount, :decimal, max_digits: 20, decimal_places: 4, default: 0
      column :probability, :int, default: 0
      column :expected_close_on, :date, null: true
      column :owner_id, :big_int, null: true, index: true
      column :stage_id, :big_int, index: true
      column :source_id, :big_int, null: true
      column :loss_reason_id, :big_int, null: true
      column :loss_note, :text, default: ""
      column :closed_at, :date_time, null: true
      column :created_by_id, :big_int, null: true
      column :created_at, :date_time
      column :updated_at, :date_time
    end

    create_table :crm_stage_change do
      column :id, :big_int, primary_key: true, auto: true
      column :opportunity_id, :big_int, index: true
      column :from_stage_id, :big_int, null: true
      column :to_stage_id, :big_int
      column :user_id, :big_int, null: true
      column :cause, :string, max_size: 32, default: ""
      column :created_at, :date_time
    end

    create_table :crm_document_link do
      column :id, :big_int, primary_key: true, auto: true
      column :opportunity_id, :big_int, index: true
      column :document_id, :big_int, unique: true
      column :kind, :string, max_size: 16
      column :created_by_id, :big_int, null: true
      column :created_at, :date_time
    end

    create_table :crm_activity do
      column :id, :big_int, primary_key: true, auto: true
      column :kind, :string, max_size: 16
      column :subject, :string, max_size: 200
      column :due_on, :date, index: true
      column :starts_at, :date_time, null: true
      column :duration_minutes, :int, null: true
      column :owner_id, :big_int, null: true, index: true
      column :report, :text, default: ""
      column :done, :bool, default: false
      column :done_at, :date_time, null: true
      column :organization_id, :big_int, null: true, index: true
      column :contact_id, :big_int, null: true, index: true
      column :opportunity_id, :big_int, null: true, index: true
      column :created_by_id, :big_int, null: true
      column :created_at, :date_time
      column :updated_at, :date_time
    end

    CONSTRAINTS.each { |(forward, backward)| execute(forward, backward) }
  end
end
