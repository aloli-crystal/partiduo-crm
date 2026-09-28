# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private alias S = Crm::SpecSupport
private alias Api = Crm::Api

describe "Relation client — tableau de bord commercial (ADR-009 D6)" do
  it "pondère le pipeline par étape et par responsable, compte gagnées, perdues, motifs, retards" do
    S.setup
    bruno = S.user_id("bruno@example.com")
    S.opportunity("A", amount: "10000")                                                   # Découverte 10 % : 1 000
    S.opportunity("B", amount: "4000", stage_id: S.stage("proposal").id, owner_id: bruno) # Proposition 50 % : 2 000
    won = S.opportunity("C", amount: "7000")
    lost = S.opportunity("D", amount: "3000")
    lost_again = S.opportunity("E", amount: "1000")
    Api.move_opportunity(S.writer, won.id, Api::MoveInput.new(S.stage("won").id)).value!
    Api.move_opportunity(S.writer, lost.id, Api::MoveInput.new(S.stage("lost").id, S.reason("price").id)).value!
    Api.move_opportunity(S.writer, lost_again.id, Api::MoveInput.new(S.stage("lost").id, S.reason("price").id)).value!
    Api.create_activity(S.seller, Api::ActivityInput.new(kind: "task", subject: "En retard", due_on: S.today - 1.day,
      organization_id: S.organization.id)).value!

    board = I18n.with_locale("fr") { Api.dashboard(S.reader) }
    board.from.should eq(S.date("2026-01-01"))
    board.to.should eq(S.date("2026-12-31"))
    board.by_stage.map { |row| {row.label, row.count, row.amount, row.weighted_amount} }.should eq([
      {"Découverte", 1_i64, S.d("10000"), S.d("1000")}, {"Qualification", 0_i64, S.d("0"), S.d("0")},
      {"Proposition", 1_i64, S.d("4000"), S.d("2000")}, {"Négociation", 0_i64, S.d("0"), S.d("0")},
    ])
    board.weighted_amount.should eq(S.d("3000"))
    board.open_count.should eq(2)
    board.by_owner.map { |row| {row.label, row.weighted_amount} }.should eq([{"Bruno Test", S.d("2000")}, {"Alice Test", S.d("1000")}])
    {board.won_count, board.won_amount, board.lost_count, board.lost_amount}.should eq({1_i64, S.d("7000"), 2_i64, S.d("4000")})
    board.conversion_rate.should eq(S.d("33.3"))
    I18n.with_locale("fr") { board.loss_reasons.map { |row| {row.label, row.count} }.should eq([{"Prix", 2_i64}]) }
    board.late_activities.should eq(1)
    board.no_next_step.should eq(2)

    # Période sans clôture : pas de taux.
    empty = Api.dashboard(S.reader, S.date("2025-01-01"), S.date("2025-12-31"))
    empty.won_count.should eq(0)
    empty.conversion_rate.should be_nil
  end

  it "fournit la tuile « Commercial » du tableau de bord du dossier" do
    S.setup
    S.opportunity("A", amount: "10000")
    tile = Api.tile(S.reader) || raise("absent")
    tile.weighted_amount.should eq(S.d("1000"))
    tile.open_count.should eq(1)
    Api.tile(Partiduo::Api::Actor.user(9_i64, [] of String)).should be_nil
  end
end
