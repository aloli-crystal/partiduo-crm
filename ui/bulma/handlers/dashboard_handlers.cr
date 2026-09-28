# SPDX-License-Identifier: AGPL-3.0-or-later

module Crm
  module Ui
    # `/ext/CRM/` : renvoie au tableau de bord commercial, qui a sa propre
    # adresse pour que le menu ne le marque pas actif sur tous les écrans de
    # l'extension (la coquille compare les préfixes d'adresse).
    class IndexHandler < Handler
      def get
        go(Ui.url("dashboard"))
      end
    end

    # `/ext/CRM/dashboard` : tableau de bord commercial (ADR-009 D6) — pipeline
    # pondéré par étape et par responsable, gagnées et perdues sur la
    # période, taux de transformation, motifs de perte, activités en retard,
    # chiffre d'affaires facturé issu des opportunités (lu dans la
    # Facturation).
    class DashboardHandler < Handler
      def get
        today = Partiduo::Api::Core.today
        from = date_query("from") || Time.utc(today.year, 1, 1)
        to = date_query("to") || Time.utc(today.year, 12, 31)
        from, to = to, from if to < from
        board = Api.dashboard(actor, from, to)
        page("crm/dashboard.html", {
          "title"   => I18n.t("crm.menu.crm_dashboard"),
          "crumbs"  => crumbs({I18n.t("crm.menu.crm_dashboard"), nil}),
          "actions" => [link_action("crm_ui.pipeline.title", Ui.url("pipeline"), "", "layout-dashboard")],
          "from"    => Ui.iso(from),
          "to"      => Ui.iso(to),
          "period"  => fmt.period(from, to),
          "tiles"   => tiles(board),
          "stages"  => bars(board.by_stage),
          "owners"  => board.by_owner.map { |row| total_row(row) },
          "reasons" => board.loss_reasons.map { |row| Ui.row({"label" => row.label, "count" => row.count.to_s}) },
        })
      end

      private def date_query(name : String) : Time?
        Ui.parse_date(query(name), fmt)
      end

      private def tiles(board : Api::DashboardView) : Array(Row)
        list = [
          tile("crm_ui.dashboard.weighted", fmt.amount(board.weighted_amount),
            I18n.t("crm_ui.dashboard.open_count", count: board.open_count), Ui.url("pipeline")),
          tile("crm_ui.dashboard.won", fmt.amount(board.won_amount), I18n.t("crm_ui.dashboard.count", count: board.won_count),
            "#{Ui.url("opportunities")}?status=won"),
          tile("crm_ui.dashboard.lost", fmt.amount(board.lost_amount), I18n.t("crm_ui.dashboard.count", count: board.lost_count),
            "#{Ui.url("opportunities")}?status=lost"),
          tile("crm_ui.dashboard.conversion", board.conversion_rate.try { |rate| "#{fmt.number(rate, 1)} %" } || "—",
            I18n.t("crm_ui.dashboard.conversion_sub"), nil),
        ]
        if invoiced = board.invoiced
          list << tile("crm_ui.dashboard.invoiced", fmt.amount(invoiced), I18n.t("crm_ui.dashboard.invoiced_sub", count: board.invoiced_count), nil)
        end
        list << tile("crm_ui.dashboard.late", board.late_activities.to_s, I18n.t("crm_ui.dashboard.late_sub"), Ui.url("activities"),
          board.late_activities > 0)
        list << tile("crm_ui.dashboard.no_next_step", board.no_next_step.to_s, I18n.t("crm_ui.dashboard.no_next_step_sub"),
          "#{Ui.url("opportunities")}?next=1", board.no_next_step > 0)
        list
      end

      private def tile(label_key : String, value : String, sub : String?, url : String?, alert : Bool = false) : Row
        Ui.row({"label" => I18n.t(label_key), "value" => value, "sub" => sub, "url" => url, "alert" => Ui.flag(alert)})
      end

      # Barres du pipeline pondéré par étape (`<progress>` relatif au plus
      # grand montant pondéré).
      private def bars(rows : Array(Api::TotalView)) : Array(Row)
        max = rows.max_of?(&.weighted_amount) || BigDecimal.new(0)
        rows.map do |row|
          width = max.zero? ? 0 : (row.weighted_amount * 100 / max).round(0).to_i
          total_row(row).tap { |item| item.values["width"] = width.to_s }
        end
      end

      private def total_row(row : Api::TotalView) : Row
        Ui.row({"label" => row.label, "count" => row.count.to_s, "amount" => fmt.amount(row.amount),
                "weighted" => fmt.amount(row.weighted_amount)})
      end
    end
  end
end
