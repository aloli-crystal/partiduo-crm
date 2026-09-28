# SPDX-License-Identifier: AGPL-3.0-or-later

module Crm
  module Ui
    # `/ext/CRM/import` : import CSV des organisations et contacts (ADR-009
    # D8), en trois temps sur le même écran : fichier (ou texte collé),
    # aperçu avec la correspondance des colonnes à ajuster et les doublons
    # signalés (SIREN, courriel, nom), import des lignes retenues et bilan.
    class ImportHandler < Handler
      MAX_BYTES    = 2 * 1024 * 1024
      PREVIEW_ROWS = 200

      def get
        show_start
      end

      def post
        upload = request.data.fetch("file", nil).as?(Marten::HTTP::UploadedFile)
        content = upload.try { |file| read(file) } || field("content", strip: false)
        return show_start(I18n.t("crm_ui.import.too_large"), 422) if content.bytesize > MAX_BYTES
        return show_start(I18n.t("crm_ui.import.invalid_encoding"), 422) unless content.valid_encoding?
        input = Api::ImportInput.new(content, nil, field("legal_basis"), id_field("source_id"))
        first = Api.preview_import(actor, input)
        return show_start(messages(first), 422) if first.failure?
        input = input.copy_with(mapping: mapping(first.value!.headers)) if field("mapped") == "1"

        if field("step") == "import"
          result = Api.import(actor, input)
          return show_report(result.value!) if result.success?
          return show_preview(input, nil, messages(result))
        end
        preview = Api.preview_import(actor, input)
        preview.success? ? show_preview(input, preview.value!, nil) : show_preview(input, nil, messages(preview))
      ensure
        upload.try { |file| file.io.delete rescue nil }
      end

      private def read(file : Marten::HTTP::UploadedFile) : String
        io = file.io
        io.rewind
        String.new(io.getb_to_end)
      end

      private def messages(result) : String
        result.errors.map { |error| fmt.message(error) }.join(" ")
      end

      # Correspondance saisie : une liste par colonne (`map_<rang>`).
      private def mapping(headers : Array(String)) : Hash(String, String)
        headers.each_with_index.to_h { |header, index| {header, field("map_#{index}")} }
      end

      private def base_values : Hash(String, (String | Array(Screen::Crumb) | Array(Row))?)
        {
          "title"  => I18n.t("crm_ui.import.title"),
          "crumbs" => crumbs({I18n.t("crm_ui.import.title"), nil}).as(Array(Screen::Crumb)),
        } of String => (String | Array(Screen::Crumb) | Array(Row))?
      end

      private def choice_rows(options : Array(Form::Option), selected : String) : Array(Row)
        options.map { |item| Ui.row({"value" => item.value, "label" => item.label, "selected" => Ui.flag(item.value == selected)}) }
      end

      private def show_start(error : String? = nil, status : Int32 = 200) : Marten::HTTP::Response
        values = base_values
        values["step"] = "start"
        values["error"] = error
        values["legal_bases"] = choice_rows(code_options(Api::LEGAL_BASES, "crm.legal_bases", blank: true), field("legal_basis"))
        values["sources"] = choice_rows(source_options, field("source_id"))
        values["fields"] = Api::IMPORT_FIELDS.map { |name| Ui.row({"label" => I18n.t("crm.import.fields.#{name}")}) }
        page("crm/import.html", values, status: status)
      end

      private def show_preview(input : Api::ImportInput, preview : Api::ImportPreviewView?, error : String?) : Marten::HTTP::Response
        values = base_values
        values["step"] = "preview"
        values["error"] = error
        values["content"] = input.content
        values["legal_basis"] = input.legal_basis
        values["source_id"] = input.source_id.to_s
        if preview
          field_options = [Form::Option.new("", I18n.t("crm_ui.import.ignore"))] +
                          Api::IMPORT_FIELDS.map { |name| Form::Option.new(name, I18n.t("crm.import.fields.#{name}")) }
          values["columns"] = preview.headers.map_with_index do |header, index|
            Ui.row({"index" => index.to_s, "header" => header}, {"options" => choice_rows(field_options, preview.mapping[header]? || "")})
          end
          mapped = preview.headers.select { |header| !preview.mapping[header]?.to_s.empty? }
          values["mapped_headers"] = mapped.map { |header| Ui.row({"label" => I18n.t("crm.import.fields.#{preview.mapping[header]}")}) }
          values["rows"] = preview.rows.first(PREVIEW_ROWS).map { |row| preview_row(row, mapped.map { |header| preview.mapping[header] }) }
          values["summary"] = I18n.t("crm_ui.import.summary", count: preview.rows.size, importable: preview.importable_count)
          values["importable"] = preview.importable_count > 0 ? I18n.t("crm_ui.import.submit", count: preview.importable_count) : nil
          values["truncated"] = preview.rows.size > PREVIEW_ROWS ? I18n.t("crm_ui.import.truncated", count: PREVIEW_ROWS) : nil
        end
        page("crm/import.html", values, status: preview ? 200 : 422)
      end

      private def preview_row(row : Api::ImportRowView, fields : Array(String)) : Row
        note = if cause = row.duplicate
                 I18n.t("crm.import.duplicates.#{cause}", name: row.duplicate_of || "")
               elsif !row.errors.empty?
                 row.errors.map { |error| [field_label(error.field), fmt.message(error)].compact.join(" : ") }.join(" ")
               end
        Ui.row({
          "line"      => row.line.to_s,
          "note"      => note,
          "state"     => row.duplicate ? "skip" : (row.errors.empty? ? "ok" : "error"),
          "state_tag" => I18n.t(row.importable? ? "crm_ui.import.state_ok" : (row.duplicate ? "crm_ui.import.state_duplicate" : "crm_ui.import.state_error")),
        }, {"cells" => fields.map { |name| Ui.row({"value" => row.values[name]? || ""}) }})
      end

      # Libellé du champ d'une erreur de ligne (`organization_siren`), `nil`
      # pour une erreur d'ensemble.
      private def field_label(name : String) : String?
        name = "organization_country" if name == "organization_country_code"
        Api::IMPORT_FIELDS.includes?(name) ? I18n.t("crm.import.fields.#{name}") : nil
      end

      private def show_report(report : Api::ImportReportView) : Marten::HTTP::Response
        values = base_values
        values["step"] = "report"
        values["report"] = I18n.t("crm_ui.import.report", organizations: report.organizations, contacts: report.contacts)
        values["skipped"] = report.skipped.map do |row|
          reason = row.duplicate.try { |cause| I18n.t("crm.import.duplicates.#{cause}", name: row.duplicate_of || "") } ||
                   row.errors.map { |error| fmt.message(error) }.join(" ")
          Ui.row({"line" => row.line.to_s, "reason" => reason})
        end
        page("crm/import.html", values)
      end
    end
  end
end
