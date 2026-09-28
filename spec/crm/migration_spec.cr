# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private alias S = Crm::SpecSupport

private def sql_error(sql : String, *args) : String?
  Marten::DB::Connection.default.open(&.exec(sql, *args))
  nil
rescue ex : PQ::PQError
  ex.message
end

describe "Relation client — migration et intégrité en base (ADR-003 D5)" do
  it "range ses tables sous le préfixe crm_" do
    [Crm::Stage, Crm::LossReason, Crm::Source, Crm::Organization, Crm::Contact, Crm::Opportunity, Crm::StageChange,
     Crm::DocumentLink, Crm::Activity].map(&.db_table).all?(&.starts_with?("crm_")).should be_true
  end

  it "pose les mêmes valeurs initiales que Crm::Defaults" do
    connection = Marten::DB::Connection.default
    %w[crm_stage crm_loss_reason crm_source].each { |table| connection.open(&.exec("DELETE FROM #{table}")) }
    Migration::Crm::V0001::CONSTRAINTS.select(&.[0].includes?("INSERT INTO")).each do |(forward, _backward)|
      connection.open(&.exec(forward))
    end
    Crm::Stage.all.order(:position).map { |row| {row.code, row.position, row.probability, row.kind} }
      .should eq(Crm::Defaults::STAGES.map { |(code, position, probability, kind)| {code, position, probability, kind} })
    Crm::LossReason.all.order(:position).map(&.code).should eq(Crm::Defaults::LOSS_REASONS)
    Crm::Source.all.order(:position).map(&.code).should eq(Crm::Defaults::SOURCES)
    # Déjà remplies : `ensure!` n'ajoute rien.
    Crm::Defaults.ensure!
    Crm::Stage.all.count.should eq(6)
  end

  it "refuse en base une seconde étape « Gagnée », une probabilité hors bornes, une activité sans rattachement" do
    S.setup
    sql_error("INSERT INTO crm_stage (code, name, position, probability, kind, active, created_at, updated_at) " \
              "VALUES ('', 'Encore gagnée', 5, 100, 'won', TRUE, now(), now())").to_s.should contain("crm_stage_closing_unique")
    sql_error("UPDATE crm_stage SET probability = 101 WHERE code = 'discovery'").to_s.should contain("crm_stage_probability_check")
    sql_error("UPDATE crm_stage SET probability = 50 WHERE code = 'won'").to_s.should contain("crm_stage_closing_check")
    sql_error("INSERT INTO crm_activity (kind, subject, due_on, report, done, created_at, updated_at) " \
              "VALUES ('call', 'Sans cible', now(), '', FALSE, now(), now())").to_s.should contain("crm_activity_target_check")
    organization = S.organization
    sql_error("UPDATE crm_organization SET nature = 'club' WHERE id = $1", organization.id).to_s.should contain("crm_organization_nature_check")
    sql_error("INSERT INTO crm_contact (last_name, legal_basis, created_at, updated_at, civility, first_name, job_title, email, " \
              "phone, mobile, opposition_note, notes) VALUES ('X', 'hunch', now(), now(), '', '', '', '', '', '', '', '')")
      .to_s.should contain("crm_contact_legal_basis_check")
  end
end
