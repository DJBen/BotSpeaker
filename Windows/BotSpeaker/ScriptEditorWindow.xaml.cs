using System.Windows;
using System.Windows.Controls;

namespace BotSpeaker;

public partial class ScriptEditorWindow : Window
{
    private readonly AppModel _model;
    private Guid? _editingCustomScriptId;

    public ScriptEditorWindow(AppModel model)
    {
        _model = model;
        InitializeComponent();
        Closing += (_, e) =>
        {
            e.Cancel = true;
            Hide();
        };
    }

    public void PrepareForNewScript()
    {
        _editingCustomScriptId = null;
        Heading.Text = "Add a custom script";
        TitleBox.Text = "";
        BodyBox.Text = "";
        SaveError.Visibility = Visibility.Collapsed;
        UpdateWordCount();
    }

    public void PrepareForSelectedScript()
    {
        var selected = _model.SelectedScript;
        if (selected.CustomId is Guid id &&
            _model.CustomScripts.FirstOrDefault(c => c.Id == id) is CustomSpeechScript script)
        {
            _editingCustomScriptId = id;
            Heading.Text = "Edit custom script";
            TitleBox.Text = script.Title;
            BodyBox.Text = script.Text;
        }
        else
        {
            _editingCustomScriptId = null;
            Heading.Text = "Add a custom script";
            TitleBox.Text = "";
            BodyBox.Text = "";
        }
        SaveError.Visibility = Visibility.Collapsed;
        UpdateWordCount();
    }

    private void OnTextChanged(object sender, TextChangedEventArgs e) => UpdateWordCount();

    private void UpdateWordCount()
    {
        int count = BodyBox.Text.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries).Length;
        WordCount.Text = $"{count} words";
    }

    private void OnSaveClick(object sender, RoutedEventArgs e)
    {
        try
        {
            // WPF TextBox produces \r\n; normalize so chunk offsets match rendering.
            var text = BodyBox.Text.Replace("\r\n", "\n");
            _model.SaveCustomScript(_editingCustomScriptId, TitleBox.Text, text);
            SaveError.Visibility = Visibility.Collapsed;
            Hide();
        }
        catch (AppException error)
        {
            SaveError.Text = error.Message;
            SaveError.Visibility = Visibility.Visible;
        }
    }

    private void OnCancelClick(object sender, RoutedEventArgs e) => Hide();
}
