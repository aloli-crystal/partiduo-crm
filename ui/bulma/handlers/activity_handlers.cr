# SPDX-License-Identifier: AGPL-3.0-or-later

module Crm
  module Ui
    # Tableau des activités d'une organisation, d'un contact ou d'une
    # opportunité (rubrique d'une consultation), avec « Fait » et
    # « Modifier ».
    def self.activity_table(handler : Handler, views : Array(Api::ActivityView), path : String, id : String) : PartiduoUi::Table
      fmt = handler.fmt
      today = Partiduo::Api::Core.today
      columns = [
        PartiduoUi::Table::Column.new("due", I18n.t("crm_ui.activities.due_on"), "mono"),
        PartiduoUi::Table::Column.new("kind", I18n.t("crm_ui.activities.kind"), secondary: true),
        PartiduoUi::Table::Column.new("subject", I18n.t("crm_ui.activities.subject")),
        PartiduoUi::Table::Column.new("owner", I18n.t("crm_ui.activities.owner"), secondary: true),
        PartiduoUi::Table::Column.new("state", I18n.t("crm_ui.activities.state")),
        PartiduoUi::Table::Column.new("actions", I18n.t("crm_ui.activities.actions"), "actions"),
      ]
      rows = views.map do |view|
        state = if view.done
                  I18n.t("crm_ui.activities.done")
                elsif view.late?(today)
                  I18n.t("crm_ui.activities.late")
                else
                  I18n.t("crm_ui.activities.to_do")
                end
        actions = [] of PartiduoUi::Screen::Action
        if handler.can_write?
          unless view.done
            actions << PartiduoUi::Screen::Action.new(I18n.t("crm_ui.activities.mark_done"), Ui.url("activity_done", id: view.id),
              "post", "small", "check")
          end
          actions << PartiduoUi::Screen::Action.new(I18n.t("ui.forms.edit"), Ui.url("activity_edit", id: view.id), "get", "small")
        end
        subject = view.report.empty? ? view.subject : "#{view.subject} — #{view.report}"
        PartiduoUi::Table::Row.new([
          PartiduoUi::Table::Cell.new(fmt.date(view.due_on), sort: view.due_on.to_s("%Y-%m-%d")),
          PartiduoUi::Table::Cell.new(I18n.t(view.kind_key)),
          PartiduoUi::Table::Cell.new(subject),
          PartiduoUi::Table::Cell.new(view.owner_id.try { |owner| handler.owners[owner]? } || ""),
          PartiduoUi::Table::Cell.new(state),
          PartiduoUi::Table::Cell.new("", actions: actions),
        ], view.late?(today) ? "crm-late" : "")
      end
      table = PartiduoUi::Table.new(I18n.t("crm_ui.activities.title"), columns, rows, path,
        empty_message: I18n.t("crm_ui.activities.none"), id: id)
      table.exportable = false
      table
    end

    # Formulaire d'une activité (création, modification).
    abstract class ActivityScreen < Handler
      FIELDS = %w[kind subject due_on starts_at duration_minutes owner_id report done organization_id contact_id opportunity_id]

      def activity_crumbs(title : String) : Array(Screen::Crumb)
        crumbs({I18n.t("crm.menu.crm_activities"), Ui.url("activities")}, {title, nil})
      end

      def values_of(view : Api::ActivityView?) : Hash(String, String)
        unless view
          return {"kind" => "call", "due_on" => Ui.iso(Partiduo::Api::Core.today), "owner_id" => actor.user_id.to_s,
                  "organization_id" => query("organization"), "contact_id" => query("contact"),
                  "opportunity_id" => query("opportunity")}
        end
        {
          "kind" => view.kind, "subject" => view.subject, "due_on" => Ui.iso(view.due_on),
          "starts_at" => view.starts_at.try(&.to_s("%H:%M")) || "", "duration_minutes" => view.duration_minutes.to_s,
          "owner_id" => view.owner_id.to_s, "report" => view.report, "done" => view.done ? "1" : "",
          "organization_id" => view.organization_id.to_s, "contact_id" => view.contact_id.to_s,
          "opportunity_id" => view.opportunity_id.to_s,
        }
      end

      def submitted : Hash(String, String)
        FIELDS.to_h { |name| {name, field(name, strip: name != "report")} }
      end

      def activity_form(values : Hash(String, String)) : Form
        value = ->(name : String) { values[name]? || "" }
        main = [
          Form::Field.new("kind", I18n.t("crm_ui.activities.kind"), "select", value.call("kind"),
            options: code_options(Api::ACTIVITY_KINDS, "crm.activity_kinds"), required: true),
          Form::Field.new("subject", I18n.t("crm_ui.activities.subject"), value: value.call("subject"), required: true,
            maxlength: 200, wide: true),
          Form::Field.new("due_on", I18n.t("crm_ui.activities.due_on"), "date", value.call("due_on"), required: true),
          Form::Field.new("starts_at", I18n.t("crm_ui.activities.starts_at"), value: value.call("starts_at"), mono: true,
            maxlength: 5, placeholder: "10:30", help: I18n.t("crm_ui.activities.starts_at_help")),
          Form::Field.new("duration_minutes", I18n.t("crm_ui.activities.duration"), "number", value.call("duration_minutes"),
            mono: true),
          Form::Field.new("owner_id", I18n.t("crm_ui.activities.owner"), "select", value.call("owner_id"), options: owner_options),
          Form::Field.new("report", I18n.t("crm_ui.activities.report"), "textarea", value.call("report"), wide: true),
          Form::Field.new("done", I18n.t("crm_ui.activities.done"), "checkbox", value.call("done")),
        ]
        targets = [
          Form::Field.new("opportunity_id", I18n.t("crm_ui.activities.opportunity"), "select", value.call("opportunity_id"),
            options: opportunity_options),
          Form::Field.new("organization_id", I18n.t("crm_ui.activities.organization"), "select", value.call("organization_id"),
            options: organization_options(blank: true)),
          Form::Field.new("contact_id", I18n.t("crm_ui.activities.contact"), "select", value.call("contact_id"),
            options: contact_options),
        ]
        Form.new([Form::Group.new(nil, main), Form::Group.new(I18n.t("crm_ui.activities.targets"), targets)])
      end

      # Saisie lue du formulaire ; l'heure (`HH:MM`) s'ajoute à l'échéance.
      def read_input(form : Form) : Api::ActivityInput?
        due = date_field("due_on")
        form.add_error("due_on", I18n.t("ui.forms.invalid_date")) if due.nil? && !field("due_on").empty?
        starts_at = nil
        unless field("starts_at").empty?
          match = field("starts_at").match(/\A(\d{1,2})[:h](\d{2})\z/)
          if match && due && match[1].to_i < 24 && match[2].to_i < 60
            starts_at = due + match[1].to_i.hours + match[2].to_i.minutes
          else
            form.add_error("starts_at", I18n.t("crm_ui.activities.starts_at_invalid"))
          end
        end
        duration = field("duration_minutes").empty? ? nil : int_field("duration_minutes")
        form.add_error("duration_minutes", I18n.t("ui.forms.invalid_integer")) if duration.nil? && !field("duration_minutes").empty?
        return if form.invalid
        Api::ActivityInput.new(kind: field("kind"), subject: field("subject"), due_on: due, starts_at: starts_at,
          duration_minutes: duration, owner_id: id_field("owner_id"), report: field("report", strip: false),
          done: field("done") == "1", organization_id: id_field("organization_id"), contact_id: id_field("contact_id"),
          opportunity_id: id_field("opportunity_id"))
      end

      # Retour après l'enregistrement : la page d'origine (`next`) ou
      # « Mes activités ».
      def back : String
        PartiduoUi::Navigation.safe_path(field("next").presence || query("next").presence) || Ui.url("activities")
      end
    end

    # `/ext/CRM/activities` : « Mes activités » (ADR-009 D4) — en retard,
    # aujourd'hui, à venir ; un autre responsable se choisit.
    class ActivitiesHandler < Handler
      def get
        owner = query("owner").to_i64? || actor.user_id
        agenda = Api.agenda(actor, owner)
        today = Partiduo::Api::Core.today
        present = ->(views : Array(Api::ActivityView)) { views.map { |view| Present.activity(view, fmt, owners, today) } }
        actions = can_write? ? [link_action("crm_ui.activities.new", Ui.url("activity_new"), "primary", "plus")] : [] of Screen::Action
        page("crm/activities.html", {
          "title"   => I18n.t("crm.menu.crm_activities"),
          "crumbs"  => crumbs({I18n.t("crm.menu.crm_activities"), nil}),
          "actions" => actions,
          "groups"  => [
            Ui.row({"key" => "late", "label" => I18n.t("crm_ui.activities.group_late"), "count" => agenda.late.size.to_s},
              {"items" => present.call(agenda.late)}),
            Ui.row({"key" => "today", "label" => I18n.t("crm_ui.activities.group_today"), "count" => agenda.today.size.to_s},
              {"items" => present.call(agenda.today)}),
            Ui.row({"key" => "upcoming", "label" => I18n.t("crm_ui.activities.group_upcoming"), "count" => agenda.upcoming.size.to_s},
              {"items" => present.call(agenda.upcoming)}),
          ],
          "owners"    => owners.to_a.sort_by!(&.[1]).map { |(id, name)| Ui.row({"value" => id.to_s, "label" => name, "selected" => Ui.flag(owner == id)}) },
          "can_write" => Ui.flag(can_write?),
          "next"      => Ui.url("activities"),
        })
      end
    end

    class ActivityNewHandler < ActivityScreen
      def get
        show(activity_form(values_of(nil)))
      end

      def post
        form = activity_form(submitted)
        if input = read_input(form)
          result = Api.create_activity(actor, input)
          if result.success?
            flash["success"] = I18n.t("crm_ui.flash.activity_created")
            return go(back)
          end
          form.add_errors(result.errors, fmt)
        end
        show(form)
      end

      private def show(form : Form) : Marten::HTTP::Response
        title = I18n.t("crm_ui.activities.new")
        form_page(title, activity_crumbs(title), form, Ui.url("activity_new"), I18n.t("ui.forms.create"), Ui.url("activities"))
      end
    end

    class ActivityEditHandler < ActivityScreen
      def get
        view = Api.activity(actor, id_param)
        show(view, activity_form(values_of(view)))
      end

      def post
        view = Api.activity(actor, id_param)
        form = activity_form(submitted)
        if input = read_input(form)
          result = Api.update_activity(actor, view.id, input)
          if result.success?
            flash["success"] = I18n.t("crm_ui.flash.saved")
            return go(back)
          end
          form.add_errors(result.errors, fmt)
        end
        show(view, form)
      end

      private def show(view : Api::ActivityView, form : Form) : Marten::HTTP::Response
        actions = [post_action("crm_ui.activities.delete", Ui.url("activity_delete", id: view.id), "crm_ui.activities.delete_confirm",
          "danger", "x")]
        form_page(view.subject, activity_crumbs(view.subject), form, Ui.url("activity_edit", id: view.id), I18n.t("ui.forms.save"),
          Ui.url("activities"), actions)
      end
    end

    # Marque une activité faite, avec le compte rendu saisi (« Mes
    # activités »).
    class ActivityDoneHandler < ActivityScreen
      def get
        go(Ui.url("activities"))
      end

      def post
        report = field("report", strip: false).presence
        after(Api.complete_activity(actor, id_param, report: report), "crm_ui.flash.done", back)
      end
    end

    class ActivityDeleteHandler < ActivityScreen
      def get
        go(Ui.url("activities"))
      end

      def post
        after(Api.delete_activity(actor, id_param), "crm_ui.flash.deleted", Ui.url("activities"))
      end
    end
  end
end
