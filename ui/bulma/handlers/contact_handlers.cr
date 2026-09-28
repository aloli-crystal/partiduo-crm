# SPDX-License-Identifier: AGPL-3.0-or-later

module Crm
  module Ui
    # Formulaire d'un contact (création, modification), consentement RGPD
    # compris (origine, base légale datée).
    abstract class ContactScreen < Handler
      FIELDS = %w[organization_id civility first_name last_name job_title email phone mobile source_id legal_basis
        legal_basis_on notes]

      def contact_crumbs(title : String? = nil, url : String? = nil) : Array(Screen::Crumb)
        list = crumbs({I18n.t("crm.menu.crm_contacts"), title ? Ui.url("contacts") : nil})
        list << Screen::Crumb.new(title, url) if title
        list
      end

      def values_of(view : Api::ContactView?) : Hash(String, String)
        return {"organization_id" => query("organization")} unless view
        {
          "organization_id" => view.organization_id.to_s, "civility" => view.civility, "first_name" => view.first_name,
          "last_name" => view.last_name, "job_title" => view.job_title, "email" => view.email, "phone" => view.phone,
          "mobile" => view.mobile, "source_id" => view.source_id.to_s, "legal_basis" => view.legal_basis,
          "legal_basis_on" => Ui.iso(view.legal_basis_on), "notes" => view.notes,
        }
      end

      def submitted : Hash(String, String)
        FIELDS.to_h { |name| {name, field(name, strip: name != "notes")} }
      end

      def contact_form(values : Hash(String, String)) : Form
        value = ->(name : String) { values[name]? || "" }
        person = [
          Form::Field.new("civility", I18n.t("crm_ui.contacts.civility"), "select", value.call("civility"),
            options: code_options(Api::CIVILITIES, "crm.civilities", blank: true)),
          Form::Field.new("first_name", I18n.t("crm_ui.contacts.first_name"), value: value.call("first_name"), maxlength: 100),
          Form::Field.new("last_name", I18n.t("crm_ui.contacts.last_name"), value: value.call("last_name"), required: true,
            maxlength: 100),
          Form::Field.new("job_title", I18n.t("crm_ui.contacts.job_title"), value: value.call("job_title"), maxlength: 100),
          Form::Field.new("organization_id", I18n.t("crm_ui.contacts.organization"), "select", value.call("organization_id"),
            options: organization_options(blank: true)),
          Form::Field.new("email", I18n.t("crm_ui.contacts.email"), "email", value.call("email"), maxlength: 254),
          Form::Field.new("phone", I18n.t("crm_ui.contacts.phone"), value: value.call("phone"), maxlength: 32),
          Form::Field.new("mobile", I18n.t("crm_ui.contacts.mobile"), value: value.call("mobile"), maxlength: 32),
        ]
        consent = [
          Form::Field.new("source_id", I18n.t("crm_ui.contacts.source"), "select", value.call("source_id"), options: source_options),
          Form::Field.new("legal_basis", I18n.t("crm_ui.contacts.legal_basis"), "select", value.call("legal_basis"),
            options: code_options(Api::LEGAL_BASES, "crm.legal_bases", blank: true), help: I18n.t("crm_ui.contacts.legal_basis_help")),
          Form::Field.new("legal_basis_on", I18n.t("crm_ui.contacts.legal_basis_on"), "date", value.call("legal_basis_on")),
          Form::Field.new("notes", I18n.t("crm_ui.contacts.notes"), "textarea", value.call("notes"), wide: true),
        ]
        Form.new([Form::Group.new(nil, person), Form::Group.new(I18n.t("crm_ui.contacts.consent_group"), consent)])
      end

      def read_input(form : Form) : Api::ContactInput?
        basis_on = field("legal_basis_on").empty? ? nil : date_field("legal_basis_on")
        if basis_on.nil? && !field("legal_basis_on").empty?
          form.add_error("legal_basis_on", I18n.t("ui.forms.invalid_date"))
          return
        end
        Api::ContactInput.new(last_name: field("last_name"), first_name: field("first_name"),
          organization_id: id_field("organization_id"), civility: field("civility"), job_title: field("job_title"),
          email: field("email"), phone: field("phone"), mobile: field("mobile"), source_id: id_field("source_id"),
          legal_basis: field("legal_basis"), legal_basis_on: basis_on, notes: field("notes", strip: false))
      end
    end

    # `/ext/CRM/contacts` : contacts utilisables (sans les opposés, onglet à
    # part), export CSV de la liste et export pour une action commerciale.
    class ContactsHandler < ContactScreen
      def get
        opposed = query("tab") == "opposed"
        views = Api.contacts(actor, Api::ContactQuery.new(opposed: opposed, limit: Api::MAX_LIMIT))
        params = {"q" => query("q"), "tab" => query("tab")}.reject { |_, value| value.empty? }
        actions = [link_action("crm_ui.contacts.export", Ui.url("contacts_export"), "", "download")]
        actions << link_action("crm_ui.contacts.new", Ui.url("contact_new"), "primary", "plus") if can_write?
        tabs = [Screen::Tab.new(I18n.t("crm_ui.contacts.tab_active"), Ui.url("contacts"), !opposed),
                Screen::Tab.new(I18n.t("crm_ui.contacts.tab_opposed"), "#{Ui.url("contacts")}?tab=opposed", opposed)]
        list_page(I18n.t("crm.menu.crm_contacts"), table(views, params), crumbs, "crm_ui.contacts.csv_name", actions, tabs,
          I18n.t("crm_ui.contacts.tabs"), search_filters([Form::Field.new("tab", "", "hidden", query("tab"))]),
          opposed ? I18n.t("crm_ui.contacts.opposed_intro") : nil)
      end

      private def table(views : Array(Api::ContactView), params : Hash(String, String)) : Table
        columns = [
          Table::Column.new("name", I18n.t("crm_ui.contacts.name")),
          Table::Column.new("organization", I18n.t("crm_ui.contacts.organization")),
          Table::Column.new("job", I18n.t("crm_ui.contacts.job_title"), secondary: true),
          Table::Column.new("email", I18n.t("crm_ui.contacts.email")),
          Table::Column.new("phone", I18n.t("crm_ui.contacts.phone"), secondary: true),
          Table::Column.new("basis", I18n.t("crm_ui.contacts.legal_basis"), secondary: true),
        ]
        rows = views.map do |view|
          Table::Row.new([
            Table::Cell.new(view.full_name, Ui.url("contact", id: view.id), sort: "#{view.last_name} #{view.first_name}".downcase),
            Table::Cell.new(view.organization_name || "", view.organization_id.try { |id| Ui.url("organization", id: id) }),
            Table::Cell.new(view.job_title),
            Table::Cell.new(view.email),
            Table::Cell.new(view.phone.presence || view.mobile),
            Table::Cell.new(view.legal_basis_key.try { |key| I18n.t(key) } || ""),
          ])
        end
        Table.new(I18n.t("crm.menu.crm_contacts"), columns, rows, Ui.url("contacts"), params, I18n.t("crm_ui.contacts.none"),
          "crm-contacts")
      end
    end

    # `/ext/CRM/contacts/export` : CSV des contacts non opposés (action
    # commerciale, ADR-009 D2 et D8).
    class ContactsExportHandler < Handler
      def get
        response = Marten::HTTP::Response.new(content: Api.export_contacts(actor), content_type: "text/csv; charset=utf-8")
        response["Content-Disposition"] = %(attachment; filename="#{I18n.t("crm_ui.contacts.export_name")}-#{Time.local.to_s("%Y%m%d")}.csv")
        response
      end
    end

    class ContactNewHandler < ContactScreen
      def get
        show(contact_form(values_of(nil)))
      end

      def post
        form = contact_form(submitted)
        if input = read_input(form)
          result = Api.create_contact(actor, input)
          if view = result.value?
            flash["success"] = I18n.t("crm_ui.flash.contact_created")
            return go(Ui.url("contact", id: view.id))
          end
          form.add_errors(result.errors, fmt)
        end
        show(form)
      end

      private def show(form : Form) : Marten::HTTP::Response
        title = I18n.t("crm_ui.contacts.new")
        form_page(title, contact_crumbs(title), form, Ui.url("contact_new"), I18n.t("ui.forms.create"), Ui.url("contacts"))
      end
    end

    class ContactEditHandler < ContactScreen
      def get
        view = Api.contact(actor, id_param)
        show(view, contact_form(values_of(view)))
      end

      def post
        view = Api.contact(actor, id_param)
        form = contact_form(submitted)
        if input = read_input(form)
          result = Api.update_contact(actor, view.id, input)
          if result.success?
            flash["success"] = I18n.t("crm_ui.flash.saved")
            return go(Ui.url("contact", id: view.id))
          end
          form.add_errors(result.errors, fmt)
        end
        show(view, form)
      end

      private def show(view : Api::ContactView, form : Form) : Marten::HTTP::Response
        url = Ui.url("contact", id: view.id)
        form_page(I18n.t("crm_ui.contacts.edit"), contact_crumbs(view.full_name, url), form, Ui.url("contact_edit", id: view.id),
          I18n.t("ui.forms.save"), url)
      end
    end

    # `/ext/CRM/contacts/<id>` : coordonnées, consentement (RGPD),
    # opportunités et activités ; opposition, levée, effacement.
    class ContactHandler < ContactScreen
      def get
        view = Api.contact(actor, id_param)
        sections = [summary(view), consent(view),
                    Screen::Section.new(I18n.t("crm_ui.activities.title"),
                      table: Ui.activity_table(self, Api.activities(actor, Api::ActivityQuery.new(contact_id: view.id)),
                        Ui.url("contact", id: view.id), "crm-contact-activities"))]
        intro = view.opposed? ? I18n.t("crm_ui.contacts.opposed_help", date: fmt.date(view.opposed_at)) : nil
        detail_page(view.full_name, contact_crumbs(view.full_name), sections, actions(view),
          view.opposed? ? I18n.t("crm_ui.contacts.opposed") : nil, intro)
      end

      private def actions(view : Api::ContactView) : Array(Screen::Action)
        list = [] of Screen::Action
        if can_write?
          unless view.opposed?
            list << link_action("crm_ui.activities.new", "#{Ui.url("activity_new")}?contact=#{view.id}", "", "calendar")
            list << post_action("crm_ui.contacts.record_opposition", Ui.url("contact_opposition", id: view.id),
              "crm_ui.contacts.record_opposition_confirm", "", "lock")
          end
          list << link_action("ui.forms.edit", Ui.url("contact_edit", id: view.id), "", "notebook-pen")
        end
        if can_admin?
          if view.opposed?
            list << post_action("crm_ui.contacts.withdraw_opposition", Ui.url("contact_withdraw", id: view.id),
              "crm_ui.contacts.withdraw_opposition_confirm", "", "key-round")
          end
          unless Api.contact_quoted?(actor, view.id)
            list << post_action("crm_ui.contacts.erase", Ui.url("contact_erase", id: view.id), "crm_ui.contacts.erase_confirm",
              "danger", "x")
          end
        end
        list
      end

      private def summary(view : Api::ContactView) : Screen::Section
        Screen::Section.new(I18n.t("crm_ui.contacts.summary"), [
          Screen::Item.new(I18n.t("crm_ui.contacts.civility"), view.civility_key.try { |key| I18n.t(key) } || ""),
          Screen::Item.new(I18n.t("crm_ui.contacts.organization"), view.organization_name || "",
            view.organization_id.try { |id| Ui.url("organization", id: id) }),
          Screen::Item.new(I18n.t("crm_ui.contacts.job_title"), view.job_title),
          Screen::Item.new(I18n.t("crm_ui.contacts.email"), view.email, view.email.empty? ? nil : "mailto:#{view.email}"),
          Screen::Item.new(I18n.t("crm_ui.contacts.phone"), view.phone),
          Screen::Item.new(I18n.t("crm_ui.contacts.mobile"), view.mobile),
          Screen::Item.new(I18n.t("crm_ui.contacts.notes"), view.notes),
        ])
      end

      private def consent(view : Api::ContactView) : Screen::Section
        Screen::Section.new(I18n.t("crm_ui.contacts.consent_group"), [
          Screen::Item.new(I18n.t("crm_ui.contacts.source"), view.source_id.try { |id| Api.sources(actor).find(&.id.==(id)).try(&.label) } || "—"),
          Screen::Item.new(I18n.t("crm_ui.contacts.legal_basis"), view.legal_basis_key.try { |key| I18n.t(key) } || I18n.t("crm_ui.contacts.no_basis")),
          Screen::Item.new(I18n.t("crm_ui.contacts.legal_basis_on"), view.legal_basis_on.try { |date| fmt.date(date) } || ""),
          Screen::Item.new(I18n.t("crm_ui.contacts.opposed_at"), view.opposed_at.try { |time| fmt.date(time) } || ""),
          Screen::Item.new(I18n.t("crm_ui.contacts.opposition_note"), view.opposition_note),
        ], note: I18n.t("crm_ui.contacts.rgpd_note"))
      end
    end

    class ContactOppositionHandler < Handler
      def get
        go(Ui.url("contact", id: id_param))
      end

      def post
        after(Api.record_opposition(actor, id_param, field("note")), "crm_ui.flash.opposed", Ui.url("contact", id: id_param))
      end
    end

    class ContactWithdrawHandler < Handler
      def get
        go(Ui.url("contact", id: id_param))
      end

      def post
        after(Api.withdraw_opposition(actor, id_param), "crm_ui.flash.withdrawn", Ui.url("contact", id: id_param))
      end
    end

    class ContactEraseHandler < Handler
      def get
        go(Ui.url("contact", id: id_param))
      end

      def post
        result = Api.erase_contact(actor, id_param)
        after(result, "crm_ui.flash.erased", result.success? ? Ui.url("contacts") : Ui.url("contact", id: id_param))
      end
    end
  end
end
