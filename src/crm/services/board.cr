# SPDX-License-Identifier: AGPL-3.0-or-later

module Crm
  # Tableau de bord commercial (ADR-009 D6) : pipeline pondéré par étape et
  # par responsable, opportunités gagnées et perdues sur la période, motifs
  # de perte, activités en retard, chiffre d'affaires facturé issu des
  # opportunités — lu dans la Facturation par le contrat, jamais recopié.
  # Interne.
  module Board
    alias Api = Crm::Api
    alias Inv = Partiduo::Api::Invoicing

    def self.build(actor : Partiduo::Api::Actor, from : Time, to : Time) : Api::DashboardView
      stages = Records.stages
      open_ids = stages.select(&.kind.==("open")).map(&.id!.to_i64)
      open_rows = Opportunity.filter(stage_id__in: open_ids).to_a
      open_views = Records.opportunity_views(open_rows)

      by_stage = stages.select(&.kind.==("open")).compact_map do |stage|
        views = open_views.select(&.stage_id.==(stage.id))
        next if views.empty? && !stage.active
        total(Records.stage_view(stage).label, views, stage.id.try(&.to_i64))
      end
      users = Records.users
      by_owner = open_views.group_by(&.owner_id).map do |owner_id, views|
        name = owner_id.try { |id| users[id]?.try { |user| Records.user_name(user) } } || I18n.t("crm.dashboard.no_owner")
        total(name, views, owner_id)
      end.sort_by! { |row| {-row.weighted_amount, row.label} }

      won_stage = Records.closing_stage("won").id
      lost_stage = Records.closing_stage("lost").id
      last = to + 1.day
      won = Opportunity.filter(stage_id: won_stage, closed_at__gte: from, closed_at__lt: last).to_a
      lost = Opportunity.filter(stage_id: lost_stage, closed_at__gte: from, closed_at__lt: last).to_a
      reasons = LossReason.all.to_a.to_h { |row| {row.id!.to_i64, Records.choice_view(row).label} }
      loss_reasons = lost.group_by(&.loss_reason_id).map do |id, rows|
        Api::ReasonCountView.new(id.try { |value| reasons[value.to_i64]? } || "—", rows.size.to_i64)
      end.sort_by! { |row| {-row.count, row.label} }

      invoiced, invoiced_count = invoiced(actor, from, to)
      Api::DashboardView.new(
        from: from, to: to, by_stage: by_stage, by_owner: by_owner,
        won_count: won.size.to_i64, won_amount: won.sum(BigDecimal.new(0)) { |row| row.amount || BigDecimal.new(0) },
        lost_count: lost.size.to_i64, lost_amount: lost.sum(BigDecimal.new(0)) { |row| row.amount || BigDecimal.new(0) },
        loss_reasons: loss_reasons, late_activities: late_activities,
        no_next_step: open_views.count(&.no_next_step?).to_i64, invoiced: invoiced, invoiced_count: invoiced_count,
      )
    end

    def self.total(label : String, views : Array(Api::OpportunityView), id : Int64?) : Api::TotalView
      Api::TotalView.new(label, views.size.to_i64, views.sum(BigDecimal.new(0), &.amount),
        views.sum(BigDecimal.new(0), &.weighted_amount), id)
    end

    # Activités à faire dont l'échéance est passée (`owner_id` : d'un
    # responsable seulement).
    def self.late_activities(owner_id : Int64? = nil) : Int64
      query = Activity.filter(done: false, due_on__lt: Records.today)
      query = query.filter(owner_id: owner_id) if owner_id
      query.count.to_i64
    end

    # Chiffre d'affaires HT des factures rattachées aux opportunités, émises
    # sur la période, relu document par document dans la Facturation ;
    # `nil` si l'acteur ne peut pas la lire (D-CRM-009).
    def self.invoiced(actor : Partiduo::Api::Actor, from : Time, to : Time) : {BigDecimal?, Int64}
      return {nil, 0_i64} unless actor.can?(Inv::READ)
      total = BigDecimal.new(0)
      count = 0_i64
      DocumentLink.filter(kind: "invoice").each do |link|
        document = begin
          Inv.document(actor, link.document_id!.to_i64)
        rescue Partiduo::Api::NotFound
          next
        end
        date = document.issue_date
        next if document.number.nil? || date.nil? || date < from || date > to
        total += document.totals.total_net
        count += 1
      end
      {total, count}
    rescue Partiduo::Api::AccessDenied
      {nil, 0_i64}
    end
  end
end
