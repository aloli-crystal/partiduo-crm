# SPDX-License-Identifier: AGPL-3.0-or-later

module Crm
  module Ui
    # `/ext/CRM/settings` : paramétrage de la relation client (`crm.admin`,
    # ADR-009 D3, D7) — étapes du pipeline (nom, probabilité par défaut,
    # ordre, activité ; « Gagnée » et « Perdue » fixes), motifs de perte,
    # origines. Une ligne par formulaire ; une saisie refusée est
    # réaffichée avec ses erreurs sous la ligne.
    class SettingsHandler < Handler
      KINDS = %w[stages reasons sources]

      def get
        render_settings
      end

      # `failed` : ligne refusée (`stages-4`, `reasons-new`…), ses valeurs
      # saisies et ses messages.
      def render_settings(failed : String? = nil, values = {} of String => String, messages = [] of String,
                          status : Int32 = 200) : Marten::HTTP::Response
        stage_rows = Api.stages(actor).map do |stage|
          setting_row("stages", stage.id.to_s, stage.name, stage.label, stage.position, stage.active, failed, values, messages,
            probability: stage.probability, fixed: stage.closing?)
        end
        reason_rows = Api.loss_reasons(actor).map do |reason|
          setting_row("reasons", reason.id.to_s, reason.name, reason.label, reason.position, reason.active, failed, values, messages)
        end
        source_rows = Api.sources(actor).map do |source|
          setting_row("sources", source.id.to_s, source.name, source.label, source.position, source.active, failed, values, messages)
        end
        page("crm/settings.html", {
          "title"  => I18n.t("crm_ui.settings.title"),
          "crumbs" => [crumb("core.menu.settings"), Screen::Crumb.new(I18n.t("crm_ui.settings.title"))],
          "panels" => [
            panel("stages", "crm_ui.settings.stages", "crm_ui.settings.stages_help", stage_rows, failed, values, messages, true),
            panel("reasons", "crm_ui.settings.reasons", "crm_ui.settings.reasons_help", reason_rows, failed, values, messages, false),
            panel("sources", "crm_ui.settings.sources", "crm_ui.settings.sources_help", source_rows, failed, values, messages, false),
          ],
          "actions" => [] of Screen::Action,
        }, status: status)
      end

      private def panel(kind : String, title : String, help : String, rows : Array(Row), failed : String?,
                        values : Hash(String, String), messages : Array(String), probability : Bool) : Row
        blank = setting_row(kind, "new", "", "", 0, true, failed, values, messages, probability: probability ? 0 : nil)
        Ui.row({"kind" => kind, "title" => I18n.t(title), "help" => I18n.t(help),
                "create_url" => Ui.url("settings_create", kind: kind), "probability" => Ui.flag(probability)},
          {"rows" => rows, "blank" => [blank]})
      end

      private def setting_row(kind : String, id : String, name : String, label : String, position : Int32, active : Bool,
                              failed : String?, values : Hash(String, String), messages : Array(String),
                              probability : Int32? = nil, fixed : Bool = false) : Row
        key = "#{kind}-#{id}"
        refused = failed == key
        Ui.row({
          "key"         => key,
          "id"          => id,
          "name"        => refused ? values["name"]? : name,
          "placeholder" => name.empty? ? label : nil,
          "label"       => label,
          "position"    => refused ? values["position"]? : position.to_s,
          "probability" => probability.try { |value| refused ? values["probability"]? : value.to_s },
          "active"      => Ui.flag(refused ? values["active"]? == "1" : active),
          "fixed"       => Ui.flag(fixed),
          "url"         => id == "new" ? Ui.url("settings_create", kind: kind) : Ui.url("settings_update", kind: kind, id: id.to_i64),
          "errors"      => refused ? messages.join(" ") : nil,
        })
      end
    end

    # Enregistre une ligne de paramétrage : création (`/settings/<genre>`)
    # ou modification (`/settings/<genre>/<id>`).
    abstract class SettingsCommand < SettingsHandler
      def get
        go(Ui.url("settings"))
      end

      def kind : String
        value = params["kind"].to_s
        raise Partiduo::Api::NotFound.new("crm_settings", 0_i64) unless KINDS.includes?(value)
        value
      end

      def save(id : Int64?) : Marten::HTTP::Response
        values = {"name" => field("name"), "position" => field("position"), "probability" => field("probability"),
                  "active" => field("active")}
        position = field("position").to_i32? || -1
        active = field("active") == "1"
        result = case kind
                 when "stages"
                   input = Api::StageInput.new(field("name"), field("probability").to_i32? || -1, position, active)
                   id ? Api.update_stage(actor, id, input) : Api.create_stage(actor, input)
                 when "reasons"
                   input = Api::ChoiceInput.new(field("name"), position, active)
                   id ? Api.update_loss_reason(actor, id, input) : Api.create_loss_reason(actor, input)
                 else
                   input = Api::ChoiceInput.new(field("name"), position, active)
                   id ? Api.update_source(actor, id, input) : Api.create_source(actor, input)
                 end
        if result.success?
          flash["success"] = I18n.t("crm_ui.flash.saved")
          return go(Ui.url("settings"))
        end
        render_settings("#{kind}-#{id || "new"}", values, result.errors.map { |error| fmt.message(error) }, 422)
      end
    end

    class SettingsCreateHandler < SettingsCommand
      def post
        save(nil)
      end
    end

    class SettingsUpdateHandler < SettingsCommand
      def post
        save(id_param)
      end
    end
  end
end
