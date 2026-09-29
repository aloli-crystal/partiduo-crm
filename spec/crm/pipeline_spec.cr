# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private alias S = Crm::SpecSupport
private alias Api = Crm::Api

describe "Relation client — opportunités et pipeline (ADR-009 D3)" do
  it "crée une opportunité à la première étape, probabilité de l'étape, création historisée" do
    S.setup
    view = S.opportunity("Agencement boutique", amount: "12000.50", expected_close_on: S.date("2026-11-30"),
      source_id: S.source("referral").id)
    view.stage.code.should eq("discovery")
    view.probability.should eq(10)
    view.amount.should eq(S.d("12000.50"))
    view.weighted_amount.should eq(S.d("1200.05"))
    view.owner_id.should eq(S.user_id("alice@example.com"))
    view.status.should eq("open")
    view.no_next_step?.should be_true
    history = Api.stage_history(S.reader, view.id)
    history.map { |change| {change.from_stage.try(&.code), change.to_stage.code, change.cause} }.should eq([{nil, "discovery", "created"}])
    history.first.user_id.should eq(S.user_id("alice@example.com"))

    custom = S.opportunity("Sur mesure", probability: 40, stage_id: S.stage("negotiation").id)
    custom.stage.code.should eq("negotiation")
    custom.probability.should eq(40)
  end

  it "contrôle la saisie d'une opportunité" do
    S.setup
    organization = S.organization
    result = Api.create_opportunity(S.seller, Api::OpportunityInput.new(title: "", organization_id: 999_i64,
      amount: S.d("-1"), probability: 120, stage_id: S.stage("won").id, owner_id: 999_i64))
    result.errors.map { |error| {error.field, error.key} }.should eq([
      {"organization_id", "crm.errors.opportunity.organization_id.unknown"},
      {"amount", "crm.errors.opportunity.amount.negative"},
      {"stage_id", "crm.errors.opportunity.stage_id.invalid"},
      {"probability", "crm.errors.opportunity.probability.range"},
      {"title", "crm.errors.opportunity.title.blank"},
      {"owner_id", "crm.errors.opportunity.owner_id.unknown"},
    ])
    Api.create_opportunity(S.seller, Api::OpportunityInput.new(title: "Centimes", organization_id: organization.id,
      amount: S.d("1.234"))).error_keys.should eq(["crm.errors.opportunity.amount.scale"])
  end

  it "déplace d'étape en étape, historise qui, quand, d'où et vers où ; « Perdue » exige un motif" do
    S.setup
    view = S.opportunity
    moved = Api.move_opportunity(S.writer, view.id, Api::MoveInput.new(S.stage("qualification").id)).value!
    moved.stage.code.should eq("qualification")
    moved.probability.should eq(25)

    Api.move_opportunity(S.writer, view.id, Api::MoveInput.new(S.stage("lost").id))
      .error_keys.should eq(["crm.errors.opportunity.loss_reason_id.blank"])
    Api.move_opportunity(S.writer, view.id, Api::MoveInput.new(999_i64))
      .error_keys.should eq(["crm.errors.opportunity.stage_id.invalid"])
    lost = Api.move_opportunity(S.writer, view.id, Api::MoveInput.new(S.stage("lost").id, S.reason("price").id, "Trop cher")).value!
    lost.status.should eq("lost")
    lost.probability.should eq(0)
    lost.closed_at.should_not be_nil
    lost.loss_note.should eq("Trop cher")
    lost.no_next_step?.should be_false

    # Réouverte : clôture et motif effacés.
    reopened = Api.move_opportunity(S.writer, view.id, Api::MoveInput.new(S.stage("negotiation").id)).value!
    reopened.closed_at.should be_nil
    reopened.loss_reason_id.should be_nil
    won = Api.move_opportunity(S.writer, view.id, Api::MoveInput.new(S.stage("won").id)).value!
    won.probability.should eq(100)
    won.status_key.should eq("crm.opportunity_statuses.won")

    history = Api.stage_history(S.reader, view.id)
    history.map { |change| {change.from_stage.try(&.code), change.to_stage.code} }.should eq([
      {nil, "discovery"}, {"discovery", "qualification"}, {"qualification", "lost"}, {"lost", "negotiation"},
      {"negotiation", "won"},
    ])
    history[1].user_id.should eq(S.user_id("bruno@example.com"))
    # Même étape : rien n'est historisé.
    Api.move_opportunity(S.writer, view.id, Api::MoveInput.new(S.stage("won").id)).success?.should be_true
    Api.stage_history(S.reader, view.id).size.should eq(5)
  end

  it "garde l'historique en ajout seul (déclencheur de la migration)" do
    S.setup
    view = S.opportunity
    expect_raises(Exception, /ajout seul/) do
      Marten::DB::Connection.default.open(&.exec("UPDATE crm_stage_change SET cause = '' WHERE opportunity_id = $1", view.id))
    end
    expect_raises(Exception, /ajout seul/) do
      Marten::DB::Connection.default.open(&.exec("DELETE FROM crm_stage_change WHERE opportunity_id = $1", view.id))
    end
  end

  it "présente le pipeline en colonnes, avec montants et montants pondérés par étape" do
    S.setup
    first = S.opportunity("A", amount: "1000")
    S.opportunity("B", amount: "3000", stage_id: S.stage("proposal").id)
    S.opportunity("C", amount: "500", stage_id: S.stage("proposal").id, owner_id: S.user_id("bruno@example.com"))
    Api.move_opportunity(S.writer, first.id, Api::MoveInput.new(S.stage("won").id)).value!

    pipeline = Api.pipeline(S.reader)
    pipeline.columns.map { |column| {column.stage.code, column.opportunities.size} }.should eq([
      {"discovery", 0}, {"qualification", 0}, {"proposal", 2}, {"negotiation", 0}, {"won", 1}, {"lost", 0},
    ])
    proposal = pipeline.columns[2]
    proposal.amount.should eq(S.d("3500"))
    proposal.weighted_amount.should eq(S.d("1750"))
    pipeline.weighted_amount.should eq(S.d("1750"))
    Api.pipeline(S.reader, owner_id: S.user_id("bruno@example.com")).columns[2].opportunities.map(&.title).should eq(["C"])
    # Closes avant la date donnée : hors de la colonne. Instant UTC : la date
    # du dossier (son fuseau) peut précéder celle de la clôture, horodatée en UTC.
    Api.pipeline(S.reader, closed_since: Time.utc + 1.day).columns[4].opportunities.should be_empty
  end

  it "filtre la liste des opportunités" do
    S.setup
    leroux = S.organization("Menuiserie Leroux")
    S.opportunity("Agencement", leroux.id)
    other = S.opportunity("Vitrine", S.organization("Boulangerie Petit").id, amount: "800")
    Api.move_opportunity(S.writer, other.id, Api::MoveInput.new(S.stage("lost").id, S.reason("timing").id)).value!
    Api.opportunities(S.reader, Api::OpportunityQuery.new(search: "leroux")).map(&.title).should eq(["Agencement"])
    Api.opportunities(S.reader, Api::OpportunityQuery.new(status: "lost")).map(&.title).should eq(["Vitrine"])
    Api.opportunities(S.reader, Api::OpportunityQuery.new(status: "open", no_next_step: true)).map(&.title).should eq(["Agencement"])
    Api.opportunities(S.reader, Api::OpportunityQuery.new(stage_id: S.stage("discovery").id)).map(&.title).should eq(["Agencement"])
  end

  it "modifie une opportunité sans changer son étape" do
    S.setup
    view = S.opportunity
    input = Api::OpportunityInput.new(title: "Agencement complet", organization_id: view.organization_id, amount: S.d("15000"),
      probability: 30, owner_id: S.user_id("bruno@example.com"), stage_id: S.stage("won").id)
    updated = Api.update_opportunity(S.writer, view.id, input).value!
    updated.title.should eq("Agencement complet")
    updated.stage.code.should eq("discovery")
    updated.probability.should eq(30)
    updated.owner_id.should eq(S.user_id("bruno@example.com"))
  end

  it "paramètre les étapes (crm.admin) : ajout, ordre, probabilité, désactivation contrôlée" do
    S.setup
    expect_raises(Partiduo::Api::Forbidden) { Api.create_stage(S.writer, Api::StageInput.new("Démonstration", 40, 35)) }
    demo = Api.create_stage(S.admin, Api::StageInput.new("Démonstration", 40, 35)).value!
    Api.stages(S.reader).map(&.label).should contain("Démonstration")
    Api.stages(S.reader, active_only: true).map(&.id).index(demo.id).should eq(3)
    Api.create_stage(S.admin, Api::StageInput.new("", 120, 5000)).errors.map(&.field).should eq(%w[name probability position])

    discovery = S.stage("discovery")
    renamed = Api.update_stage(S.admin, discovery.id, Api::StageInput.new("Premier contact", 15, 10)).value!
    renamed.label.should eq("Premier contact")
    renamed.probability.should eq(15)
    S.opportunity.probability.should eq(15)
    Api.update_stage(S.admin, discovery.id, Api::StageInput.new("", 15, 10, active: false))
      .error_keys.should eq(["crm.errors.stage.active.in_use"])
    Api.update_stage(S.admin, demo.id, Api::StageInput.new("Démonstration", 40, 35, active: false)).value!.active.should be_false
    # « Gagnée » : probabilité et activité fixes.
    won = Api.update_stage(S.admin, S.stage("won").id, Api::StageInput.new("Signée", 10, 1000, active: false)).value!
    {won.label, won.probability, won.active}.should eq({"Signée", 100, true})
  end

  it "paramètre les motifs de perte et les origines (crm.admin)" do
    S.setup
    reason = Api.create_loss_reason(S.admin, Api::ChoiceInput.new("Délai de livraison", 70)).value!
    reason.label.should eq("Délai de livraison")
    Api.update_loss_reason(S.admin, reason.id, Api::ChoiceInput.new("Délai", 70, active: false)).value!.active.should be_false
    Api.loss_reasons(S.reader, active_only: true).map(&.id).should_not contain(reason.id)
    Api.create_source(S.admin, Api::ChoiceInput.new("", 5)).error_keys.should eq(["crm.errors.source.name.blank"])
    source = Api.create_source(S.admin, Api::ChoiceInput.new("Salon Batimat", 15)).value!
    Api.sources(S.reader, active_only: true).map(&.label).should contain("Salon Batimat")
    expect_raises(Partiduo::Api::Forbidden) { Api.update_source(S.writer, source.id, Api::ChoiceInput.new("x")) }
    Api.create_opportunity(S.seller, Api::OpportunityInput.new(title: "Motif inactif", organization_id: S.organization.id)).value!
    lost = Api.move_opportunity(S.writer, Api.opportunities(S.reader).first.id, Api::MoveInput.new(S.stage("lost").id, reason.id))
    lost.error_keys.should eq(["crm.errors.opportunity.loss_reason_id.unknown"])
  end
end
